# contracts-conconai

Smart contracts for the **ConCon (`$CON`)** ecosystem, built with [Foundry](https://book.getfoundry.sh/).

This repository currently contains the canonical, fixed-supply `$CON` ERC-20 token. Follow-up
contracts (Presale, Claim, LiquidityLocker, ListingDeposit) will bind to the token address recorded
in [`deployments/addresses.json`](deployments/addresses.json).

> ⚠️ **A professional security audit is mandatory before any mainnet use.** The code in this repo
> is delivered as-is and does not replace an audit. Claude/Cursor never holds keys and never signs
> or broadcasts on-chain transactions — **the user deploys with their own wallet.**

---

## The `$CON` token

`$CON` is a **fixed-supply, trust-minimised utility token** used to pay for listings in the ConCon
ecosystem.

| Property            | Value                                            |
| ------------------- | ------------------------------------------------ |
| Name                | `ConCon`                                         |
| Symbol              | `CON`                                            |
| Decimals            | `18`                                             |
| Total supply        | `100,000,000 CON` (`100_000_000e18`)             |
| Minting             | **None.** Entire supply minted once at deploy.   |
| Owner/admin powers  | **None** over balances.                          |
| Pause / blacklist   | **None.**                                        |
| Transfer hooks      | **None** that can block transfers.               |
| Extensions          | `ERC20Permit` (EIP-2612), `ERC20Burnable`        |

Design intent (see [`src/ConToken.sol`](src/ConToken.sol)):

- The full `100,000,000 CON` is minted to the **treasury** in the constructor and never again.
- There is **no `mint` entry point anywhere**, so supply is permanently fixed (it can only ever
  decrease via voluntary `burn` by a holder).
- There is **no owner/admin**, no pause, no blacklist, and no transfer-blocking hooks — a neutral,
  non-custodial token by design.
- `ERC20Permit` enables gasless approvals for better UX in downstream contracts.
- The constructor reverts (`ZeroTreasury`) if the treasury is the zero address.

### Canonical addresses (locked 2026-06-24)

These are **public on-chain addresses**, not secrets. They live in
[`deployments/addresses.json`](deployments/addresses.json), the single source of truth for
downstream contracts, scripts, and the frontend.

| Role                     | Address                                        |
| ------------------------ | ---------------------------------------------- |
| `$CON` token (mainnet)   | `0x7ad1A8Fc42Ac150B04dED5825D21a0C90b6d28D8`   |
| Admin / Treasury / Owner | `0x46bca9FCf2f372e76D9aE265Da725B222F5ac2e0`   |

`$CON` is **already live on Ethereum mainnet** at the token address above. On mainnet the deploy
script is therefore **reference/verification only**; downstream contracts bind to that existing
token address from `addresses.json`. The deploy script is used to put a **test copy** of the token
on Sepolia.

---

## Project layout

```
src/         ConToken.sol            canonical token (also used for Sepolia + Etherscan verify)
test/        ConToken.t.sol          Foundry tests (supply, ERC20, no-mint, permit, fuzz)
script/      DeployConToken.s.sol    deploy script (user signs with own wallet)
deployments/ addresses.json          committed canonical addresses, keyed by network
lib/         forge-std, openzeppelin-contracts (v5.1.0)
```

- Solidity `^0.8.24`, optimizer **on** (`200` runs), see [`foundry.toml`](foundry.toml).
- Remappings in [`remappings.txt`](remappings.txt).
- Linting via [solhint](https://github.com/protofire/solhint) ([`.solhint.json`](.solhint.json)).
- NatSpec on all public/external members.

---

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`).
- Node.js + npm (only for `solhint`).

### Install

```bash
forge install            # fetches lib/ dependencies if needed
npm install              # installs solhint (lint only)
```

### Environment

Copy the example env file and fill it in (it contains **no secrets**):

```bash
cp .env.example .env
```

`.env` (gitignored) holds `RPC_URL`, `ETHERSCAN_API_KEY`, and `TREASURY_ADDRESS`. **Never commit a
private key.** Signing happens at deploy time via your own wallet (hardware wallet, keystore, or
interactive prompt).

---

## Build, test, lint

```bash
forge build              # compile
forge test -vvv          # run the full test suite (incl. permit + fuzz)
forge fmt                # format
forge fmt --check        # verify formatting (CI gate)
npm run lint             # solhint
```

The test suite covers:

- `totalSupply == 100,000,000e18`, `decimals == 18`, full supply minted to treasury, name/symbol.
- `transfer` / `transferFrom` / `approve` happy paths and revert paths.
- No callable mint path (supply is capped by design).
- `ERC20Permit`: a valid signature sets the allowance; reverts on expired deadline / bad signature.
- Fuzzed transfers: amount `<=` balance succeeds, `>` balance reverts.

---

## Deploying a test copy to Sepolia

> Do **not** deploy to mainnet from this repo — `$CON` is already live there. This is for a Sepolia
> test copy / Etherscan verification only.

The deploy script reads `TREASURY_ADDRESS` from the environment (defaulting to the admin address
above) and broadcasts the deploy. **You sign with your own wallet** — there are no hardcoded keys.

```bash
# Load env (RPC_URL, ETHERSCAN_API_KEY, TREASURY_ADDRESS)
source .env

# Example: deploy with a hardware wallet (recommended), verifying on Etherscan
forge script script/DeployConToken.s.sol:DeployConToken \
  --rpc-url "$RPC_URL" \
  --ledger \
  --broadcast \
  --verify

# Or with an encrypted local keystore:
forge script script/DeployConToken.s.sol:DeployConToken \
  --rpc-url "$RPC_URL" \
  --account <keystore-name> \
  --broadcast \
  --verify
```

After a Sepolia deploy, record the deployed token address under the `sepolia` entry in
`deployments/addresses.json`.

---

## Security & trust model

- Fixed supply, **no mint backdoor**, **no pause/blacklist** on the token.
- No owner/admin power over balances.
- Revenue (in later contracts) flows to a multisig treasury.
- **An independent professional audit is required before mainnet.** This code does not replace one.

This is not financial or legal advice. ICO/securities considerations must be handled separately.
