# Threat model (MVP, mainnet-intended)

This document captures the security model and assumptions for this repo.

## Assets at risk

- **Underlying assets** deposited into vaults (e.g., USDC, WETH).
- **Vault shares** (ERC-20) representing claims on the underlying.

## Actors

- **Users (EOAs)**: deposit/withdraw, hold shares.
- **Vault owner/admin**: can toggle deposits and set TVL caps.
- **External protocols**: Aave v3, Maple/Syrup contracts.
- **Attackers**:
  - external EOA/contract attackers
  - compromised admin key
  - protocol-level exploit in upstream dependency

## Admin model

Owner powers are intentionally limited:

- Can disable deposits (`depositsDisabled`).
- Can set TVL caps (`tvlCap`).
- Cannot arbitrarily transfer user funds out of the vault (no “sweep” in production vaults).

## Primary threat surfaces

- **Reentrancy**
  - mitigated with `ReentrancyGuard` in critical hooks.
- **ERC-4626 accounting errors**
  - incorrect fee/principal accounting could over/under charge or break share pricing expectations.
- **Async withdrawals (Maple/Syrup)**
  - queueing introduces multi-step lifecycle; users may experience “withdraw pending”.
  - “one pending withdrawal per (owner, receiver)” is a constraint.
- **Allowance / approvals**
  - vaults approve protocol contracts/routers; approval logic must handle non-standard ERC20s.
- **External protocol risk**
  - Aave/Maple contract risk, oracle risk, governance risk, pause risk.

## Non-goals (explicitly out of scope for MVP)

- On-chain risk scoring, oracle reads, reward valuation.
- Complex fee models (management fees, performance fee crystallization).
- Automated rescue flows for external protocol failures.

## Assumptions

- OpenZeppelin `ERC4626` implementation correctness is relied upon.
- Underlying ERC20 tokens behave reasonably (but may have quirks; see docs/testing).
- External protocols follow their documented behavior:
  - Aave: `withdraw` returns requested assets when available.
  - Maple/Syrup: `requestRedeem` is queued and assets may arrive later.

