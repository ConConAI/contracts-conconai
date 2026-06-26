# ConConAI ($CON) Presale - Security Audit Request

## 1. Summary
We are requesting a security audit of the **$CON presale contract**. $CON is a fixed-supply ERC-20 utility
token (used to pay for listings in the ConConAI network). The token itself is standard OpenZeppelin and is
already deployed on Ethereum mainnet. The presale sells $CON for USDC/USDT/ETH, books each buyer's allocation,
awards fixed purchase-bonus tiers, and lets buyers claim their tokens after the sale.

This is a relatively small, standard presale (no cross-chain, no proxies/upgradeability, no ZK). We want a
named report with severity-classified findings and a re-check after we fix them.

## 2. Scope
- **In scope (Solidity, ~378 nSLOC, mostly Presale.sol):**
  - `src/Presale.sol` - the presale (main focus; handles funds)
  - `src/ConToken.sol` - fixed-supply ERC-20 (OpenZeppelin-based; already deployed on mainnet)
  - `src/interfaces/IAggregatorV3.sol`
- **Out of scope:** `src/mocks/*` (testnet-only mock stablecoins + mock oracle), `test/*` (provided as
  context), LP-locking at DEX listing (handled via an established third-party locker, not our code), and the
  web frontend / admin app.
- **Repo:** github.com/ConConAI/contracts-conconai (private; read access or ZIP provided).
- **Commit / tag:** `<final frozen commit / tag, e.g. audit-2026-06>` - please review exactly this commit.
- **No proxies / not upgradeable.** Code is frozen for the duration of the audit.

## 3. Tech
- Solidity `^0.8.24`, Foundry (forge). OpenZeppelin Contracts v5.x (Ownable2Step, Pausable, ReentrancyGuard,
  SafeERC20, ERC20/ERC20Permit/ERC20Burnable).
- Target chain: **Ethereum mainnet**. Fully tested on **Sepolia**.

## 4. What the Presale does
- **Buy (book, do not transfer):** `buyWithStable` (USDC/USDT, 6 decimals, counted 1:1 with USD) and
  `buyWithETH` (priced via a Chainlink ETH/USD feed with zero/negative/stale/incomplete-round guards). The
  buyer's $CON is recorded in `purchased[buyer]`; no $CON moves until claim.
- **Phases:** 5 phases priced $0.005-$0.009 (stored as USD with 1e6 scale), per-phase base cap 10,000,000 $CON.
  The active phase sets the price. The owner may activate any phase (free switching).
- **Caps:** per-phase base cap (10M) plus a global `PRESALE_CAP` of 50,000,000 $CON over base + bonus; buys are
  clamped to the remaining cap and charged exactly (ETH overpayment refunded under the reentrancy guard).
- **Bonus (fixed, stacking, once per tier):** by cumulative USD contributed per buyer - >= $10,000 -> +50,000
  $CON, >= $25,000 -> +150,000, >= $50,000 -> +400,000 (reaching $50k = +600,000 total). Bonus is drawn from
  the 50M pool (no extra mint), counted in `totalSold`, and delivered at claim.
- **Claim:** after the owner calls `enableClaim()`, buyers call `claim()` to receive their allocation
  (pull pattern; `purchased` zeroed; per-wallet `claimed` tracked; double-claim safe).
- **Admin (Ownable2Step):** startPhase(i, duration) [any phase], setTimer/extendTimer, endPhase,
  endPresale() [one-way], enableClaim() [one-way, independent], pause/unpause (buys only; claims stay enabled),
  withdraw(asset) [payment assets only - **cannot** withdraw $CON], sweepUnsold() [only $CON in excess of
  outstanding claims].
- **Views:** previewPurchase(buyer, usdE6) -> (baseCon, bonusCon, newTier); purchased, claimed, contributedUsd,
  bonusTiersAwarded, bonusTiers, outstandingClaims, remainingInActivePhase, isBuyingActive.

## 5. Roles & assumptions
- **Owner / treasury:** controls admin actions and receives raised funds + swept unsold $CON (a hardware
  wallet or Safe on mainnet). Eligibility/geo-gating is off-chain (assumed not a security; counsel-reviewed
  terms). The owner can never mutate buyer allocations, reverse claims, or withdraw buyers' $CON.
- **$CON token:** standard 18-decimal ERC-20, no transfer fee, no pause/blacklist (already live on mainnet).
- **Payment tokens:** USDC/USDT are 6 decimals, 1:1 USD. Chainlink ETH/USD feed is 8 decimals.
- **Funding:** the treasury transfers up to 50,000,000 $CON into the presale after deploy, covering all
  base + bonus claims.

## 6. Security properties we want confirmed
- Accounting: `sum(purchased) == totalSold`; `totalSold <= PRESALE_CAP (50M)`; presale $CON balance >=
  outstanding claims (`totalSold - totalClaimed`) after funding; `phase.sold <= 10M` base per phase.
- Bonus: awarded once per tier, stacks correctly, never exceeds the global cap (clamped near sellout); the
  cumulative-USD tiering cannot be gamed.
- Funds safety: owner cannot drain or touch buyers' $CON; `withdraw` is payment-assets-only; `sweepUnsold`
  only releases true excess; one-way flags cannot be unset.
- Oracle: zero/negative/stale/incomplete-round answers reject ETH buys safely; SafeERC20 handles
  non-standard USDT; strict CEI + ReentrancyGuard on all value-moving paths; ETH refund is safe.
- Rounding/dust direction (never over-credits beyond cap, never under-funds claims).

## 7. Provided
- Full Foundry test suite (`test/*`): unit + fuzz + invariant tests (buy / bonus / cap / claim / oracle /
  admin / Ownable2Step). The lifecycle/architecture notes are available on request.

## 8. Deliverables requested
Named audit report with severity-classified findings and remediation guidance, plus a re-check after we apply
fixes. Optional team/KYC verification if offered. Please share **quote, timeline, and availability**. We will
deploy the exact audited commit to mainnet and verify the source on Etherscan.

## 9. Contact
ConConAI / CubeChain Media - `<your contact email>`
