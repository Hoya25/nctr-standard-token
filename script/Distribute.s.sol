// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LedgerCsv} from "./lib/LedgerCsv.sol";

/// @notice Turns the migration ledger into Safe Transaction Builder batch files.
/// @dev Never signs and never broadcasts. It only reads one CSV and writes JSON files.
///
/// Env:
///   TOKEN            new token address (the `to` of every transfer)
///   SAFE             Safe that holds the supply (recorded in each file's meta)
///   LEDGER_PATH      default ./ledger/MIGRATION-LEDGER.csv (git-ignored; never commit it)
///   OUT_DIR          default ./out-batches (git-ignored)
///   BATCH_SIZE       default 50, must be 1..50
///   INCLUDE_STATUS   default "pending": only rows whose `status` equals this exactly.
///                    Exact match, not a prefix: "pending: dust (<1 NCTR)" and
///                    "pending: internal" are NOT selected by the default.
///   EXCLUDE_LABELS   default "UNKNOWN": rows whose `label` equals any of these exactly are
///                    skipped. Separate several with "|" (labels may contain commas). The
///                    default holds back every UNKNOWN row, including the 20 unregistered
///                    direct-transfer wallets (runbook R1), until each is relabeled. Set to
///                    an empty string to exclude nothing.
///   ALLOW_OLD_ADDRESS default false: when true, a row with no `new_address` is sent to `old_address`
///   CHAIN_ID         default 8453
///
/// Every transfer's calldata is exactly `transfer(to, amount)` (68 bytes), with no
/// ERC-8021 Builder Code suffix: these calls are executed by the Treasury Safe, and
/// Safe-executed transactions carry no suffix (relaunch ruling D1, 2026-11-20).
contract Distribute is Script {
    uint256 internal constant MAX_BATCH = 50;

    struct Transfer {
        address to;
        uint256 amount;
        bytes data;
    }

    struct BatchInfo {
        address token;
        address safe;
        uint256 chainId;
        uint256 index;
        uint256 count;
    }

    function run() external {
        address token = vm.envAddress("TOKEN");
        address safe = vm.envAddress("SAFE");
        string memory ledgerPath = vm.envOr("LEDGER_PATH", string("./ledger/MIGRATION-LEDGER.csv"));
        string memory outDir = vm.envOr("OUT_DIR", string("./out-batches"));
        uint256 batchSize = vm.envOr("BATCH_SIZE", MAX_BATCH);
        string memory includeStatus = vm.envOr("INCLUDE_STATUS", string("pending"));
        string memory excludeLabels = vm.envOr("EXCLUDE_LABELS", string("UNKNOWN"));
        bool allowOld = vm.envOr("ALLOW_OLD_ADDRESS", false);
        uint256 chainId = vm.envOr("CHAIN_ID", uint256(8453));
        require(batchSize > 0 && batchSize <= MAX_BATCH, "BATCH_SIZE must be 1..50");

        vm.createDir(outDir, true);
        Transfer[] memory transfers = buildTransfers(vm.readFile(ledgerPath), includeStatus, excludeLabels, allowOld);
        uint256 total = writeBatches(transfers, BatchInfo(token, safe, chainId, 0, 0), batchSize, outDir);

        console2.log("Transfers:         ", transfers.length);
        console2.log("Batches:           ", (transfers.length + batchSize - 1) / batchSize);
        console2.log("Total (wei):       ", total);
        console2.log("Total (whole):     ", total / 1e18);
        console2.log("Output dir:        ", outDir);
    }

    /// @notice Column positions of the ledger fields the script reads.
    struct Cols {
        uint256 old_;
        uint256 new_;
        uint256 bal;
        uint256 status;
        uint256 label;
    }

    /// @notice Parse the ledger and return one transfer per selected row.
    function buildTransfers(string memory csv, string memory includeStatus, string memory excludeLabels, bool allowOld)
        public
        pure
        returns (Transfer[] memory out)
    {
        string[][] memory rows = LedgerCsv.parse(csv);
        require(rows.length > 0, "empty ledger");
        string[] memory header = rows[0];
        Cols memory c = Cols(
            _col(header, "old_address"),
            _col(header, "new_address"),
            _col(header, "balance_total"),
            _col(header, "status"),
            _col(header, "label")
        );
        bytes32 want = keccak256(bytes(includeStatus));
        string[] memory skip = bytes(excludeLabels).length == 0 ? new string[](0) : vm.split(excludeLabels, "|");

        out = new Transfer[](rows.length - 1);
        uint256 n;
        for (uint256 r = 1; r < rows.length; r++) {
            string[] memory row = rows[r];
            require(row.length == header.length, "row has wrong column count");
            if (keccak256(bytes(row[c.status])) != want) continue;
            if (_listed(skip, row[c.label])) continue;
            Transfer memory t = _transfer(row, c, allowOld);
            if (t.amount == 0) continue;
            out[n++] = t;
        }
        assembly {
            mstore(out, n)
        }
    }

    /// @dev One selected row as a plain 68-byte transfer(to, amount): no suffix (D1).
    function _transfer(string[] memory row, Cols memory c, bool allowOld) private pure returns (Transfer memory t) {
        string memory dest = row[c.new_];
        if (bytes(dest).length == 0) {
            require(allowOld, "row has no new_address (set ALLOW_OLD_ADDRESS=true to use old_address)");
            dest = row[c.old_];
        }
        t.to = vm.parseAddress(dest);
        require(t.to != address(0), "zero recipient");
        t.amount = LedgerCsv.toWei(row[c.bal]);
        t.data = abi.encodeCall(IERC20.transfer, (t.to, t.amount));
    }

    function writeBatches(Transfer[] memory transfers, BatchInfo memory info, uint256 batchSize, string memory outDir)
        internal
        returns (uint256 total)
    {
        info.count = (transfers.length + batchSize - 1) / batchSize;
        for (uint256 b = 0; b < info.count; b++) {
            uint256 start = b * batchSize;
            uint256 end = start + batchSize;
            if (end > transfers.length) end = transfers.length;
            info.index = b + 1;
            (string memory json, uint256 sum) = batchJson(transfers, start, end, info);
            total += sum;
            vm.writeFile(string.concat(outDir, "/batch-", _pad3(b + 1), ".json"), json);
        }
    }

    /// @notice Safe Transaction Builder JSON for transfers[start:end].
    function batchJson(Transfer[] memory t, uint256 start, uint256 end, BatchInfo memory info)
        public
        pure
        returns (string memory json, uint256 sum)
    {
        string memory txs;
        for (uint256 i = start; i < end; i++) {
            sum += t[i].amount;
            txs = string.concat(txs, i == start ? "" : ",", _txJson(info.token, t[i].data));
        }
        json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(info.chainId),
            '","createdAt":0,"meta":',
            _metaJson(info.safe, info.index, info.count, end - start, sum),
            ',"transactions":[',
            txs,
            "]}"
        );
    }

    function _txJson(address token, bytes memory data) private pure returns (string memory) {
        return string.concat(
            '{"to":"',
            vm.toString(token),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}'
        );
    }

    function _metaJson(address safe, uint256 index, uint256 count, uint256 n, uint256 sum)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"name":"Migration batch ',
            vm.toString(index),
            " of ",
            vm.toString(count),
            '","description":"',
            vm.toString(n),
            " ERC-20 transfers, total ",
            vm.toString(sum),
            ' wei.","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":""}'
        );
    }

    function _listed(string[] memory list, string memory value) private pure returns (bool) {
        bytes32 h = keccak256(bytes(value));
        for (uint256 i = 0; i < list.length; i++) {
            if (keccak256(bytes(list[i])) == h) return true;
        }
        return false;
    }

    function _col(string[] memory header, string memory name) private pure returns (uint256 i) {
        i = LedgerCsv.column(header, name);
        require(i != type(uint256).max, string.concat("missing column: ", name));
    }

    function _pad3(uint256 n) private pure returns (string memory) {
        if (n < 10) return string.concat("00", vm.toString(n));
        if (n < 100) return string.concat("0", vm.toString(n));
        return vm.toString(n);
    }
}
