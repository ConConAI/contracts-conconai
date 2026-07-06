# SolidProof TrustNet — Rating verbessern (Übergabe-Paket)

> Ziel: den TrustNet-Score (aktuell 63.15) heben. Der Score bewertet **Audit-Ergebnis, Security, KYC,
> Social-Präsenz**. Der Code ist bereits sauber (0 Critical/High/Medium/Low). Die Punkte fehlen an
> unvollständigen Trust-Signalen, nicht am Code. Dieses Paket deckt die kostenlosen Hebel #2, #3, #4 ab.
> Beide Contracts sind **live auf Ethereum Mainnet und immutable** — Findings können daher nicht mehr im Code
> „gefixt", nur formell **acknowledged** (mit Begründung) werden. Das genügt, um sie aus „Pending" zu holen.

---

## #3 — Metadaten (die „N/A"-Felder ausfüllen)

Bei SolidProof pro Audit (Token **und** Presale) eintragen. Werte verifiziert aus `foundry.toml`,
`src/*.sol` und `deployments/addresses.json`.

### Token-Audit (Tab „Token")
| Feld | Wert |
|---|---|
| Contract Address | `0x7ad1A8Fc42Ac150B04dED5825D21a0C90b6d28D8` |
| Network | Ethereum Mainnet (chainId 1) |
| License | MIT |
| Compiler | solc 0.8.24 (optimizer on, 200 runs, EVM: cancun, bytecode_hash: none) |
| Type | ERC-20 (ERC20 + ERC20Burnable + ERC20Permit/EIP-2612), fixed supply 100,000,000 |
| Language | Solidity |

### Presale-Audit (Tab „Presale")
| Feld | Wert |
|---|---|
| Contract Address | `0x4cf6d3b066880eb081eE2A302567B452355073Ed` |
| Network | Ethereum Mainnet (chainId 1) |
| License | MIT |
| Compiler | solc 0.8.24 (optimizer on, 200 runs, EVM: cancun, bytecode_hash: none) |
| Type | Presale / Token Sale (phased, USD-priced, stacking bonus, claim-at-listing) |
| Language | Solidity |

> Beide sind auf Etherscan verifiziert — SolidProof kann Adresse/Compiler dort gegenprüfen. Etherscan-Link
> (verified): https://etherscan.io/address/0x4cf6d3b066880eb081eE2A302567B452355073Ed#code

---

## #4 — Presale-Audit bestätigt

Der „Presale"-Tab existiert und listet Static Analysis, Dynamic Analysis, Symbolic Execution, SWC Check und
Manual Review — der Presale-Contract ist also mit-auditiert. To do: nur die Metadaten oben eintragen und die
Presale-Findings (falls vorhanden) analog zu #2 acknowledgen. **Sobald wir die Presale-Findings sehen, schreibe
ich die Antworten dafür genauso.**

---

## #2 — Finding-Antworten zum Einreichen (Token / ConToken.sol)

Alle 5 sind non-blocking (1 Optimization + 4 Informational). Der Token ist live & immutable, daher jeweils
**Acknowledged** mit Begründung. Text 1:1 als Client-Response einreichbar.

### Optimization #1 — „Minor readability and bytecode notes" (L28) → **Acknowledged**
Acknowledged, no action required. The token is already deployed and immutable on Ethereum mainnet, so bytecode
cannot be changed. The flagged items are cosmetic only: numeric literals already use scientific notation with
thousands separators (e.g. `100_000_000 * 1e18`), and the duplicated public metadata constants (see Informational
#4) are retained intentionally for off-chain confirmation. No behavioural or security impact.

### Informational #1 — „Standard ERC-20 approval race condition (SWC-114)" (L20) → **Acknowledged**
Acknowledged. This is the well-known ERC-20 allowance front-running behaviour inherent to the ERC-20 standard,
not a defect in this token. The contract inherits OpenZeppelin `ERC20Permit` (EIP-2612), so integrators can set
exact allowances safely via `permit`. Recommended mitigation for integrators — approve from zero before setting a
new non-zero allowance, or use `permit` — is documented for consumers. No code change is possible or warranted on
the deployed token.

### Informational #2 — „Floating pragma and EVM target should be fixed for deployment" (L2) → **Acknowledged**
Acknowledged. Although the source declares a floating pragma (`^0.8.24`), the contract was compiled, deployed and
Etherscan-verified at a single fixed version, **solc 0.8.24**, with EVM target **cancun** (optimizer on, 200 runs)
— so the audited and deployed bytecode match. The cancun/PUSH0 target is correct for Ethereum mainnet. The
deployed token is immutable and cannot be recompiled; any future contract will pin the exact compiler version and
confirm the EVM target before deployment.

### Informational #3 — „Dependency version hygiene" (L4-6) → **Acknowledged**
Acknowledged. The token builds on OpenZeppelin Contracts 5.1.0. No security advisory affecting the specific modules
used (`ERC20`, `ERC20Burnable`, `ERC20Permit`) is known for that release. The deployed token is immutable and
cannot be upgraded. For any future/undeployed contracts we will pin the latest 5.x patch and enable automated
dependency advisory alerts so new advisories are caught early.

### Informational #4 — „Redundant public metadata constants" (L22-28) → **Acknowledged**
Acknowledged. The public `TOKEN_NAME` / `TOKEN_SYMBOL` constants intentionally mirror the standard ERC-20
`name()` / `symbol()` getters to make off-chain confirmation convenient. This is harmless and has no security
impact; it only adds a small amount of bytecode. As the token is live and immutable, the constants are retained.

---

## Zusammenfassung der Hebel

| # | Hebel | Kosten | Status/Aktion |
|---|---|---|---|
| 2 | 5 Findings acknowledgen (Text oben) | kostenlos | einreichfertig |
| 3 | Metadaten Token + Presale ausfüllen | kostenlos | Werte oben |
| 4 | Presale-Audit-Metadaten + Findings | kostenlos | Tab bestätigt; Findings noch abwarten |
| 1 | KYC-Verifizierung (separater Hebel) | kostenpflichtig | größter Score-Sprung — bei SolidProof buchen |
| 5 | Real-Time Threat Detection (Cyvers) | kostenpflichtig | optional, aktivieren für Security-Punkte |
