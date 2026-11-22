# nctr-standard-token

One small token contract, and the scripts to deploy it and hand it out.

## What the token is

`src/AllianceToken.sol` is a standard ERC-20 with permit (EIP-2612), built from OpenZeppelin v5.

- **Fixed supply.** 10,000,000,000 tokens with 18 decimals, created once when the contract is deployed.
- **All of it goes to one address** (the treasury) at deployment. Nobody else holds any at the start.
- **Nobody controls it afterwards.** There is no owner, no admin, no mint, no burn, no pause, no fee, no transfer hook and no upgrade proxy. Once deployed, the rules can never change.
- **Permit** lets a holder approve spending with a signature instead of a separate transaction.

## What is in the repo

| Path | What it does |
|---|---|
| `src/AllianceToken.sol` | The token. About 25 lines. |
| `script/Deploy.s.sol` | Deploys one token. Reads `NAME`, `SYMBOL`, `TREASURY` from the environment. Prints the address it expects (from the deployer's nonce) and the address it got. |
| `script/Distribute.s.sol` | Reads a ledger CSV and writes [Safe Transaction Builder](https://help.safe.global/en/articles/40841-transaction-builder) JSON files of at most 50 transfers each. **It never signs or sends anything.** |
| `script/lib/BuilderCode.sol` | Encodes the ERC-8021 Builder Code suffix, for transactions sent directly from a hot or Ops wallet. Migration batches (Safe-executed) do not use it. |
| `script/lib/LedgerCsv.sol` | A small CSV reader for the ledger. |
| `test/` | Unit, fuzz and invariant tests. |

## Pinned versions

| Tool | Version |
|---|---|
| Solidity | `0.8.38` exactly (`pragma solidity 0.8.38;`, `solc_version` in `foundry.toml`) |
| OpenZeppelin Contracts | `v5.7.0`, commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (git submodule + `foundry.lock`) |
| forge-std | `v1.17.0`, commit `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` |
| Foundry | `v1.9.0` (CI installs exactly this) |
| Slither / Aderyn (CI) | `0.11.6` / `0.6.8` |

## Run the tests

```sh
git clone --recursive https://github.com/Hoya25/nctr-standard-token
cd nctr-standard-token
forge test
```

The tests check that:
- the total supply is 10 billion and never changes (fuzzed transfers plus an invariant run);
- the treasury holds 100% right after deployment;
- no owner, mint, burn, pause, role, upgrade or fee function exists;
- permit works, and rejects expired, replayed or wrongly signed permits;
- a transfer with the Builder Code suffix on the end still works.

## Deploy

No keys live in this repo. Use whatever signer forge supports (hardware wallet, `--account`, etc.).

```sh
NAME="..." SYMBOL="..." TREASURY=0x... \
forge script script/Deploy.s.sol --rpc-url <base-rpc> --sender 0x<deployer> [--ledger] # add --broadcast only when ready
```

Without `--broadcast` it only simulates. The contract-creation transaction does **not** carry a Builder Code suffix: extra bytes after the constructor arguments would change the creation code that block explorers verify against.

## Build transfer batches

1. Put the ledger at `ledger/MIGRATION-LEDGER.csv`. The `ledger/` folder is git-ignored. **Never commit it.**
   Required columns: `old_address`, `label`, `new_address`, `balance_total`, `status`.
2. Run:

```sh
TOKEN=0x<new token> SAFE=0x<treasury safe> \
forge script script/Distribute.s.sol
```

Options (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `INCLUDE_STATUS` | `pending` | Only rows whose `status` is exactly this. Exact match, not a prefix: `pending: dust (<1 NCTR)` and `pending: internal` are not selected by the default. |
| `EXCLUDE_LABELS` | `UNKNOWN` | Skip rows whose `label` is exactly one of these, separated by `\|` (labels can contain commas). The default holds back every `UNKNOWN` row, including the 20 unregistered direct-transfer wallets, until each is relabeled. Set to an empty string to skip nothing. |
| `ALLOW_OLD_ADDRESS` | `false` | If `true`, a row with an empty `new_address` is paid to `old_address`. Otherwise such a row stops the script. |
| `BATCH_SIZE` | `50` | 1 to 50 transfers per file |
| `LEDGER_PATH` | `./ledger/MIGRATION-LEDGER.csv` | |
| `OUT_DIR` | `./out-batches` | |
| `CHAIN_ID` | `8453` (Base) | |

Each output file `batch-001.json`, `batch-002.json`, … can be loaded into the Safe Transaction Builder. Every transfer's calldata is exactly `transfer(to, amount)` (68 bytes) with **no** Builder Code suffix: these transfers are executed by the Treasury Safe, and Safe-executed transactions carry no suffix. (Inside a Safe batch a suffix would sit in the inner call; the outer `execTransaction` calldata ends with the owners' signatures, so ERC-8021 parsers would not see it anyway.)

**Limits to know about:**
- Amounts are read as decimals with up to 18 places. A ledger rounded to 6 places pays out the rounded amount.

## Static analysis

CI runs `forge test`, Slither (fails on any finding outside `lib/`) and Aderyn (fails on any High finding).

## License

MIT
