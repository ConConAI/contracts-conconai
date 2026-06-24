# contracts-conconai

Smart contracts for the **ConCon (`$CON`)** ecosystem, built with [Foundry](https://book.getfoundry.sh/).

This repository contains:

- the canonical, fixed-supply **`$CON`** ERC-20 token, and
- the phased **`Presale`** contract (booking + claim model) that binds to the already-deployed
  `$CON` token.

Follow-up contracts (LiquidityLocker, ListingDeposit) will likewise bind to the token address
recorded in [`deployments/addresses.json`](deployments/addresses.json).

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

## The Presale

[`src/Presale.sol`](src/Presale.sol) sells `$CON` across **5 phases** of **10,000,000 CON each**
(50M total) at fixed prices **$0.005 → $0.009**. It uses a **book-then-claim** model: a purchase
**books** the buyer's allocation (no `$CON` is transferred at purchase); after the presale the admin
opens claiming and buyers withdraw their allocation.

### Payment & pricing

- Prices are stored per token in USD at **1e6 scale** (`$0.005 == 5000`).
- **USDC / USDT** (6 decimals) count **1:1 USD**: `conAmount = stableAmount * 1e18 / priceUsdE6`.
- **ETH** is priced via the **Chainlink ETH/USD feed**. Each read requires `answer > 0`, a fresh
  `updatedAt` (heartbeat guard, `MAX_ORACLE_AGE = 1 hour`), and `answeredInRound >= roundId`, else it
  reverts. No price is ever invented.
- **Cap clamping:** a purchase that would exceed a phase cap books only the remaining amount and
  charges only the exact cost; for ETH the excess is refunded after state updates (CEI).

### Immutable config (no setters)

Set once in the constructor (reverts on any zero address): `conToken`, `usdc`, `usdt`, `ethUsdFeed`,
`treasury` (= admin/owner). The deploy script reads these from `deployments/addresses.json`.

### Admin powers (owner = treasury, `Ownable2Step`)

`startPhase(i, duration)` (sequential only), `setTimer` / `extendTimer`, `endPhase`,
`endPresale` (one-way), `enableClaim` (one-way, independent), `pause` / `unpause` (blocks buys only —
**claims stay enabled**), `withdraw(asset)` (raised USDC/USDT/ETH to treasury; **reverts for
`$CON`**), `sweepUnsold` (only the EXCESS `$CON`, always leaving outstanding claims fully covered).

The owner can **never** mutate `purchased[]`, reverse a claim, or unset the one-way flags.

### Buyer-protection / trust invariants

- `sum(purchased) + totalClaimed == totalSold`
- `conToken.balanceOf(presale) >= totalSold - totalClaimed` (outstanding claims always covered)
- `phase.sold <= cap` for every phase

---

## Project layout

```
src/            ConToken.sol            canonical token (also used for Sepolia + Etherscan verify)
                Presale.sol             phased presale (book-then-claim), binds to existing $CON
                interfaces/IAggregatorV3.sol   minimal Chainlink ETH/USD feed interface
                mocks/                  TESTNET ONLY: MockUSDC, MockUSDT, MockAggregatorV3
test/           ConToken.t.sol          token tests (supply, ERC20, no-mint, permit, fuzz)
                Presale.t.sol           presale unit + fuzz tests
                mocks/                  MockERC20 (6/18 dec), MockAggregator (Chainlink stub)
                invariant/              handler + invariant tests (accounting invariants)
script/         DeployConToken.s.sol    token deploy (reference/testnet)
                DeployPresale.s.sol     presale deploy, reads config from addresses.json
                DeploySepoliaTestEnv.s.sol   TESTNET ONLY: one-shot Sepolia env + funding
deployments/    addresses.json          committed canonical addresses, keyed by network
lib/            forge-std, openzeppelin-contracts (v5.1.0)
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

**Token** (`ConToken.t.sol`):

- `totalSupply == 100,000,000e18`, `decimals == 18`, full supply minted to treasury, name/symbol.
- `transfer` / `transferFrom` / `approve` happy paths and revert paths.
- No callable mint path (supply is capped by design).
- `ERC20Permit`: a valid signature sets the allowance; reverts on expired deadline / bad signature.
- Fuzzed transfers: amount `<=` balance succeeds, `>` balance reverts.

**Presale** (`Presale.t.sol` + `invariant/`, using mock USDC/USDT and a mock Chainlink aggregator):

- Buying with USDC / USDT / ETH books the correct CON amount at each phase price; multi-phase pricing.
- Cap clamping charges the exact required amount and books exactly the remaining; ETH excess refunded.
- Oracle guards: stale / zero / negative price revert ETH buys.
- Buys revert when the phase is not started, after `endsAt`, once `presaleEnded`, or while paused.
- Claim reverts before `enableClaim`, succeeds after, double-claim reverts, zero-allocation reverts,
  and claiming still works while paused.
- `withdraw` moves stablecoins/ETH to the treasury and reverts for `$CON`; `sweepUnsold` always keeps
  outstanding claims covered.
- One-way flags cannot be unset; non-owner reverts on every admin function; `Ownable2Step` flow.
- Fuzz + invariant tests (random buys/claims) assert the accounting invariants above.

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

### Deploying the Presale

`script/DeployPresale.s.sol` reads the immutable config (`token`, `admin`, `usdc`, `usdt`,
`ethUsdFeed`) from `deployments/addresses.json` for the chosen network and binds the presale to the
**existing** `$CON` token (it does **not** deploy a token). The network is taken from the `NETWORK`
env var, or inferred from the chain id (`1` → `mainnet`, `11155111` → `sepolia`).

For Sepolia testing, first deploy a test `$CON` copy and deploy mock 6-decimal stablecoins plus a
mock Chainlink ETH/USD aggregator, then fill their addresses into the `sepolia` entry of
`addresses.json`.

```bash
source .env

NETWORK=sepolia forge script script/DeployPresale.s.sol:DeployPresale \
  --rpc-url "$RPC_URL" \
  --ledger \
  --broadcast \
  --verify
```

**Funding the presale (required for claims).** After deploy, the **treasury transfers up to
50,000,000 `$CON` into the presale contract** so that `claim()` can pay out — this is a user action
performed with the treasury's own wallet (e.g. via a Safe). The contract enforces that outstanding
claims always remain covered, and `sweepUnsold` can only ever move the surplus back to the treasury.

Finally, record the deployed presale address under the network's `presale` entry in
`addresses.json`.

> **Lifecycle:** `startPhase` (per phase) → buyers `buyWithStable` / `buyWithETH` →
> `endPresale` (one-way) → `enableClaim` (one-way) → buyers `claim()`. `pause()` halts buying in an
> emergency without ever blocking claims.

---

## One-shot Sepolia test environment (TESTNET ONLY)

> ⚠️ **TESTNET ONLY.** `script/DeploySepoliaTestEnv.s.sol` and everything under
> [`src/mocks/`](src/mocks) (`MockUSDC`, `MockUSDT`, `MockAggregatorV3`) are for Sepolia testing only
> and **must never be deployed to mainnet**. The mocks are freely mintable and the oracle price is
> settable by anyone; the script also **reverts if run on mainnet** (chain id `1`). The real mainnet
> `$CON` is never touched — the script deploys a fresh **test copy** of the token.

Instead of wiring Sepolia by hand, this script deploys and connects the whole environment in a single
broadcast:

1. a fresh test `ConToken` (mints 100,000,000 test CON to the treasury),
2. `MockUSDC` + `MockUSDT` (6-decimal, freely mintable),
3. `MockAggregatorV3` (8-decimal ETH/USD, seeded at `$3000`),
4. a `Presale` bound to all of the above (owner/treasury = `sepolia.admin`), and
5. a transfer of **50,000,000 test CON** from the treasury into the presale so claims can pay out.

The treasury/admin is read from `deployments/addresses.json` (`sepolia.admin`). **Signing comes from
your own wallet at runtime — there are no hardcoded keys.** Because the test CON is minted to the
treasury and then moved into the presale in the same broadcast, **you must run this with the
`sepolia.admin` wallet**.

### 1. Prerequisites

- Set `sepolia.admin` in `deployments/addresses.json` to the address you will deploy from.
- In `.env`, set `RPC_URL` (a Sepolia RPC) and `ETHERSCAN_API_KEY` (for `--verify`).

### 2. Deploy the environment

```bash
source .env

# Encrypted keystore (import once via: cast wallet import sepolia-admin --interactive)
forge script script/DeploySepoliaTestEnv.s.sol:DeploySepoliaTestEnv \
  --rpc-url "$RPC_URL" \
  --account sepolia-admin \
  --broadcast \
  --verify

# ...or a hardware wallet:
forge script script/DeploySepoliaTestEnv.s.sol:DeploySepoliaTestEnv \
  --rpc-url "$RPC_URL" \
  --ledger \
  --broadcast \
  --verify
```

The run prints every deployed address plus ready-to-paste snippets for the `sepolia` entry of
`deployments/addresses.json` and for the website `.env.local`
(`NEXT_PUBLIC_*_SEPOLIA` + the presale address). Paste both in, set `NEXT_PUBLIC_ICO_LIVE=true` and
`NEXT_PUBLIC_ICO_CHAIN=sepolia` on the website, and the buy panel goes live against Sepolia.

### 3. Mint yourself test stablecoins

`MockUSDC` / `MockUSDT` use 6 decimals, so `1000 USDC = 1000000000`:

```bash
# 1,000 mUSDC to your address
cast send <MOCK_USDC> "mint(address,uint256)" <YOUR_ADDR> 1000000000 \
  --rpc-url "$RPC_URL" --account sepolia-admin

# 1,000 mUSDT
cast send <MOCK_USDT> "mint(address,uint256)" <YOUR_ADDR> 1000000000 \
  --rpc-url "$RPC_URL" --account sepolia-admin
```

### 4. Set / refresh the oracle price

The mock ETH/USD feed is seeded at `$3000` (`3000e8`). To change it (8 decimals), or to refresh the
timestamp so the presale's staleness guard passes:

```bash
# Set ETH/USD to $3,500 (also refreshes updatedAt to a fresh round)
cast send <MOCK_FEED> "setAnswer(int256)" 350000000000 \
  --rpc-url "$RPC_URL" --account sepolia-admin

# Or just refresh the timestamp (e.g. after time has passed beyond MAX_ORACLE_AGE)
cast send <MOCK_FEED> "setUpdatedAt(uint256)" $(date +%s) \
  --rpc-url "$RPC_URL" --account sepolia-admin
```

> **Funding note:** the script already moves 50,000,000 test CON into the presale, so `claim()` is
> fully covered once you run `enableClaim()`. You can then drive the lifecycle with `cast`
> (`startPhase`, buy with mock stables / ETH, `endPresale`, `enableClaim`, `claim`) or the admin
> console.

---

## Security & trust model

- **Token:** fixed supply, **no mint backdoor**, **no pause/blacklist**, no owner power over balances.
- **Presale:** immutable config (no setters), custom errors, events on every state change, strict CEI,
  `ReentrancyGuard`, `Pausable`, `Ownable2Step`, `SafeERC20`, pull-pattern claim, one-way lifecycle
  flags, and no unbounded loops / `delegatecall` / `tx.origin`.
- Buyers' booked `$CON` can never be withdrawn or swept by the admin; raised funds (USDC/USDT/ETH)
  flow to the treasury (recommended: a Safe multisig).
- The Chainlink ETH/USD read is guarded against zero/negative/stale answers and incomplete rounds.
  Verify the live feed's heartbeat against `MAX_ORACLE_AGE` and re-verify all mainnet token/oracle
  addresses against official sources before mainnet.
- **An independent professional audit is required before mainnet.** This code does not replace one.

This is not financial or legal advice. ICO/securities considerations must be handled separately.
