// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribute} from "../script/Distribute.s.sol";
import {BuilderCode} from "../script/lib/BuilderCode.sol";
import {LedgerCsv} from "../script/lib/LedgerCsv.sol";

contract DistributeTest is Test {
    Distribute internal d;

    // Reference value produced by `ox` Attribution.toDataSuffix({ codes: ["bc_90w5bpx5"] }).
    bytes internal constant EXPECTED_SUFFIX = hex"62635f39307735627078350b0080218021802180218021802180218021";

    // Row 6 is an UNKNOWN wallet (the R1 case): held back by the default EXCLUDE_LABELS.
    string internal constant CSV = "old_address,label,class,in_registry,wallet_balance,locked_total,locked_split,balance_total,origin,new_address,status\n"
        "0x1111111111111111111111111111111111111111,Alice,external,yes,1.5,0,,1.5,,,pending\n"
        "0x2222222222222222222222222222222222222222,\"Bob, with a comma\",external,no,0,2,hedgey_lockup:2,2,,0x3333333333333333333333333333333333333333,pending\n"
        "0x4444444444444444444444444444444444444444,Pool,pool,no,9,0,,9,,,EXCLUDE: pool/pool-fees; handle via liquidity plan\n"
        "0x5555555555555555555555555555555555555555,Dust,external,no,0.000001,0,,0.000001,,,pending: dust (<1 NCTR)\n"
        "0x6666666666666666666666666666666666666666,UNKNOWN,external,no,7,0,,7,,,pending\n";

    function setUp() public {
        d = new Distribute();
    }

    function test_SuffixMatchesReference() public pure {
        assertEq(BuilderCode.suffix(), EXPECTED_SUFFIX);
    }

    function test_RetiredCodeIsNotTheConstant() public pure {
        assertTrue(keccak256(bytes(BuilderCode.CODE)) != keccak256("bc_kry3r4sw"));
    }

    function test_SelectsOnlyPendingRows() public view {
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending", "UNKNOWN", true);
        assertEq(t.length, 2);
        assertEq(t[0].to, 0x1111111111111111111111111111111111111111);
        assertEq(t[0].amount, 1.5e18);
        // new_address wins over old_address.
        assertEq(t[1].to, 0x3333333333333333333333333333333333333333);
        assertEq(t[1].amount, 2e18);
    }

    function test_RevertWhen_NoNewAddressAndOldNotAllowed() public {
        vm.expectRevert();
        d.buildTransfers(CSV, "pending", "UNKNOWN", false);
    }

    /// D1: Safe-executed transfers carry no Builder Code suffix. Each call is exactly
    /// the 68-byte transfer(to, amount) and nothing after it.
    function test_EveryCallIsPlainTransferWithoutSuffix() public view {
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending", "UNKNOWN", true);
        assertGt(t.length, 0);
        for (uint256 i = 0; i < t.length; i++) {
            assertEq(t[i].data.length, 68);
            assertEq(t[i].data, abi.encodeCall(IERC20.transfer, (t[i].to, t[i].amount)));
            assertFalse(BuilderCode.hasSuffix(t[i].data, BuilderCode.CODE));
        }
    }

    function test_ExcludesUnknownLabelByDefault() public view {
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending", "UNKNOWN", true);
        assertEq(t.length, 2);
        for (uint256 i = 0; i < t.length; i++) {
            assertTrue(t[i].to != 0x6666666666666666666666666666666666666666);
        }
    }

    function test_EmptyExcludeLabelsKeepsUnknown() public view {
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending", "", true);
        assertEq(t.length, 3);
        assertEq(t[2].to, 0x6666666666666666666666666666666666666666);
        assertEq(t[2].amount, 7e18);
    }

    function test_ExcludeLabelsIsExactAndPipeSeparated() public view {
        // "Bob, with a comma" is excluded only by its exact text; "Bob" alone matches nothing.
        assertEq(d.buildTransfers(CSV, "pending", "Bob|UNKNOWN", true).length, 2);
        assertEq(d.buildTransfers(CSV, "pending", "Bob, with a comma|UNKNOWN", true).length, 1);
    }

    function test_IncludeStatusIsExactMatch() public view {
        // "pending" does not select "pending: dust (<1 NCTR)"; the exact status does.
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending: dust (<1 NCTR)", "UNKNOWN", true);
        assertEq(t.length, 1);
        assertEq(t[0].to, 0x5555555555555555555555555555555555555555);
    }

    function test_BatchJsonShape() public view {
        Distribute.Transfer[] memory t = d.buildTransfers(CSV, "pending", "UNKNOWN", true);
        (string memory json, uint256 sum) =
            d.batchJson(t, 0, t.length, Distribute.BatchInfo(address(0xAAAA), address(0xBBBB), 8453, 1, 1));
        assertEq(sum, 3.5e18);
        assertEq(vm.parseJsonString(json, ".chainId"), "8453");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), address(0xBBBB));
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), address(0xAAAA));
        assertEq(vm.parseJsonString(json, ".transactions[1].value"), "0");
        assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), t[0].data);
        assertEq(vm.parseJsonBytes(json, ".transactions[1].data"), t[1].data);
        assertFalse(vm.keyExistsJson(json, ".transactions[2]"));
    }

    function test_ToWei() public pure {
        assertEq(LedgerCsv.toWei("0"), 0);
        assertEq(LedgerCsv.toWei("1"), 1e18);
        assertEq(LedgerCsv.toWei("600000000.0"), 600_000_000e18);
        assertEq(LedgerCsv.toWei("5140207064.528212"), 5_140_207_064_528_212_000_000_000_000);
        assertEq(LedgerCsv.toWei("0.000000000000000001"), 1);
    }

    function test_RevertWhen_ToWeiGarbage() public {
        vm.expectRevert();
        this.toWeiExt("1.2.3");
        vm.expectRevert();
        this.toWeiExt("-1");
        vm.expectRevert();
        this.toWeiExt("0.0000000000000000001");
    }

    function toWeiExt(string memory s) external pure returns (uint256) {
        return LedgerCsv.toWei(s);
    }

    function testFuzz_ToWeiRoundTrip(uint64 whole, uint32 micro) public pure {
        micro = uint32(bound(micro, 0, 999_999));
        string memory frac = vm.toString(uint256(micro));
        while (bytes(frac).length < 6) frac = string.concat("0", frac);
        string memory s = string.concat(vm.toString(uint256(whole)), ".", frac);
        assertEq(LedgerCsv.toWei(s), uint256(whole) * 1e18 + uint256(micro) * 1e12);
    }
}
