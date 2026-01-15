# Invariants (audit notes)

This repo aims to keep vault logic small; these are the invariants auditors and contributors should preserve.

## ERC-4626 / shares

- **Share token is the vault itself** (ERC-20).
- **Only ERC-4626 entrypoints mint/burn shares** (no arbitrary mint).
- **Withdraw/redeem burns shares** for the `owner` address (not always the caller).

## Deposit guardrails

- If `depositsDisabled == true`, `maxDeposit(...) == 0` and deposits must revert.
- If `tvlCap != 0`, deposits must not increase `totalAssets()` beyond `tvlCap`.

## Fees (yield-only intent)

Where applicable, fees should be charged on **yield** rather than principal:

- If `totalAssets() <= totalPrincipal`, then fee should be zero for the withdrawal.
- If `totalAssets() > totalPrincipal`, the fee should be a function of the withdrawing user’s share of yield.

## Maple async withdrawals

For Maple/Syrup vault:

- A withdrawal may require **two transactions**:
  - first: initiate/record the pending redemption
  - second: finalize once assets have arrived from Maple
- At most **one pending withdrawal per `(owner, receiver)`** pair at a time.
- If a pending withdrawal exists and assets are not yet received, `withdraw` should revert (e.g., `WithdrawalPending()`), preventing double-requests under the same key.

## No-admin-custody

- Vault owner should not be able to arbitrarily move user principal out of the vault (no “sweep” in production vaults).
- Admin controls should remain limited (caps, deposit circuit breaker).

