# Audit-Fixes L-01..L-04 (Presale.sol) - cleanes Resultat

> Behebt ALLE 4 Low-Findings des automatischen Audits, ohne den normalen Ablauf einzuschraenken. Read first:
> `src/Presale.sol`. Ersetzt `AUDIT-FIX-L03-L04.md`. Stand: 2026-06-27.

## L-01 - same-block-Kauf beim Phasenwechsel
**Ursache:** `endPhase()` setzt `phase.endsAt = block.timestamp`; die Kaufpruefung ist `block.timestamp > endsAt`
(strikt). Im selben Block wie `endPhase()` geht damit noch ein Kauf zum alten Preis durch.
**Fix (lokal in `endPhase`, normale getimte Phasen unberuehrt):** Phase sofort als abgelaufen markieren.
```solidity
function endPhase() external onlyOwner {
    Phase storage phase = phases[currentPhase];
    if (!phase.started) revert PhaseNotStarted();
    // forge-lint: disable-next-line(unsafe-typecast)
    uint64 nowTs = uint64(block.timestamp);
    // L-01: mark already-expired so a buy in THIS block can no longer slip in at the old price.
    phase.endsAt = nowTs - 1;
    emit PhaseEnded(currentPhase, nowTs);
}
```
(`nowTs` ist immer >> 1, kein Underflow. Auf `block.timestamp == phase.endsAt` greift dann `now > now-1` -> revert
`PhaseExpired`.)

## L-02 - 1-Mikrodollar-Unterschreitung der Bonus-Schwelle (nur ETH)
**Ursache:** In `buyWithETH()` wird der Bonus auf `requiredUsdE6` angerechnet, das durch Doppel-Abrundung
(usd->con->usd) bis zu 0,000001 USD unter dem tatsaechlich gesendeten Wert liegt. Wer per ETH genau eine Schwelle
trifft, kann sie knapp verfehlen.
**Fix:** Beim Clamp-Status merken; Bonus auf den vollen USD-Wert der ETH anrechnen, wenn NICHT geclamped wird
(sonst auf den exakten USD-Betrag der gedeckelten Menge). Der belastete ETH-Betrag bleibt unveraendert.
```solidity
uint256 remaining = _baseRemaining(phase);
bool clamped = conAmount > remaining;          // L-02: capture before clamping
if (clamped) {
    conAmount = remaining;
}
if (conAmount == 0) revert ZeroConAmount();

uint256 requiredUsdE6 = (conAmount * price) / CON_SCALE;
uint256 requiredEth = (requiredUsdE6 * ETH_USD_SCALE) / ethUsd;
if (requiredEth > msg.value) {
    requiredEth = msg.value;
}
uint256 refund = msg.value - requiredEth;

_book(msg.sender, phaseIndex, conAmount);
emit Purchased(msg.sender, phaseIndex, conAmount, address(0), requiredEth);

// L-02: credit the full USD value of the ETH when unclamped (floor rounding on the
// CON->USD step must not drop a buyer a micro-dollar below a bonus tier); when clamped,
// credit the exact USD charged for the booked CON.
_awardBonus(msg.sender, clamped ? requiredUsdE6 : usdE6);

if (refund > 0) { ... }
```

## L-03 - Buying after sweeping unsold CON (claim backing)
**Fix:** Neuer `error PresaleNotEnded();` (zu den uebrigen errors), und `sweepUnsold()` als erste Zeile:
```solidity
if (!presaleEnded) revert PresaleNotEnded();
```
Schraenkt nichts ein - Unverkauftes sammelt man ohnehin erst nach Presale-Ende ein.

## L-04 - remainingInActivePhase() ignoriert globalen Cap
**Fix (reine View) + NatSpec klarstellen (Wert spiegelt globalen base+bonus-Cap):**
```solidity
/// @notice Remaining CON sellable as base right now: the lesser of the active phase's
///         remaining base cap and the global cap minus totalSold (which includes bonuses).
function remainingInActivePhase() external view returns (uint256) {
    Phase storage phase = phases[currentPhase];
    uint256 phaseRemaining = phase.cap - phase.sold;
    uint256 globalRemaining = PRESALE_CAP - totalSold;
    return phaseRemaining < globalRemaining ? phaseRemaining : globalRemaining;
}
```

## Tests (ergaenzen/anpassen)
- L-01: nach `endPhase()` (ohne Zeit-Warp) revertet `buyWithStable`/`buyWithETH` mit `PhaseExpired`.
- L-02: ein `buyWithETH` mit ETH-Wert exakt = `BONUS_TIER1_USD` schaltet Tier 1 frei (Bonus in `purchased`/
  `bonusTiersAwarded` enthalten); kein Verfehlen um einen Mikrodollar.
- L-03: `sweepUnsold()` revertet vor `endPresale()` mit `PresaleNotEnded`; bestehender Erfolgs-Test ruft zuerst
  `endPresale()`.
- L-04: nahe Global-Cap wird der Rueckgabewert auf den globalen Rest geclamped.
- Voller Lauf gruen: `forge build && forge test`; danach `forge fmt`. Keine sonstigen Verhaltensaenderungen.

## Cursor-Prompt (contracts-conconai)
```
Apply audit fixes L-01..L-04 in src/Presale.sol per docs/AUDIT-FIX-LOWS.md. Make only these changes.

L-01: in endPhase(), set phase.endsAt = nowTs - 1 (instead of nowTs) so a buy in the same block as endPhase() can no longer execute at the old phase price. Keep the PhaseEnded event emitting nowTs. Do not change _activePhase's comparison (normal timed phases stay as-is).

L-02: in buyWithETH(), capture `bool clamped = conAmount > remaining;` before clamping, then award the bonus on `clamped ? requiredUsdE6 : usdE6` instead of always requiredUsdE6. This credits the full USD value of the ETH for unclamped buys so floor rounding can't drop a buyer a micro-dollar below a bonus tier. Do NOT change the charged ETH (requiredEth/refund stay as they are).

L-03: add `error PresaleNotEnded();` alongside the other errors and make sweepUnsold() revert with it as its first statement: `if (!presaleEnded) revert PresaleNotEnded();`.

L-04: change remainingInActivePhase() to return the minimum of (phase.cap - phase.sold) and (PRESALE_CAP - totalSold), and update its NatSpec to state the value reflects the global base+bonus cap. Pure view; no other logic changes.

Tests: add/adjust per the doc - buy reverts PhaseExpired in the same block as endPhase; an exact-threshold ETH buy unlocks bonus tier 1; sweepUnsold reverts PresaleNotEnded before endPresale and the existing success test calls endPresale() first; remainingInActivePhase clamps to the global remaining when the global cap binds. Run `forge build && forge test` until green, then `forge fmt`. Commit + push to main.
```

## Review-Gate
- Same-block-Kauf nach `endPhase()` revertet; getimte Phasen sonst unveraendert.
- ETH-Kauf an der Bonus-Schwelle schaltet den Tier zuverlaessig frei; belasteter ETH-Betrag unveraendert.
- `sweepUnsold()` nur nach `endPresale()`; `remainingInActivePhase()` am Global-Cap korrekt.
- `forge build && forge test` gruen; alle 4 Lows adressiert, sonst nichts geaendert.
