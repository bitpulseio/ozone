# `MapleVaultAuthorized.sol` — design + behavior notes

This file implements an **ERC-4626 vault** (`MapleVault`) that routes deposits into a **Maple/Syrup pool** and supports **asynchronous withdrawals** (Maple-style queued redemptions).

It is intended as a minimal “pass-through” wrapper: users receive ERC-20 vault shares on deposit, and redeem/burn shares to withdraw underlying.

---

## What contract is deployed?

- **Contract name**: `MapleVault`
- **Standard**: `ERC4626` + `ERC20` shares
- **Underlying asset**: `asset()` (e.g., Sepolia SyrupUSDC underlying)
- **Maple position**: held via `maplePool` shares (the pool has `balanceOf`, `convertToExitAssets`, `convertToExitShares`, and `requestRedeem`)

---

## Key design goals

- **Always-open withdrawals**: there is a deposit circuit breaker (`depositsDisabled`), but withdrawals remain allowed.
- **No custody commingling risk during redemption**: withdrawals are handled in a way that matches Maple’s *queued redemption* model.
- **Yield-only fees**: fees are intended to be taken only from the user’s share of vault yield (not principal).

---

## Important state variables

- **`maplePool`** (`IMaplePool`): Maple pool proxy; the vault holds pool “shares” here.
- **`syrupRouter`** (`ISyrupRouter`): used to deposit into Maple (requires whitelist/authorization).
- **`syrupToken`** (`ISyrupToken`): syrup token address for compatibility; shares/yield accrue here depending on Maple design.

- **`depositsDisabled`**: deposit circuit breaker (withdrawals still allowed).
- **`tvlCap`**: optional cap on total assets (0 means no cap).
- **`totalPrincipal`**: accounting value tracking principal (used to compute “yield” for fees).

### Pending withdrawals

Withdrawals can be asynchronous, so the contract tracks a single pending withdrawal per `(owner, receiver)` pair:

- **`pendingWithdrawals[withdrawalKey]`**
  - `withdrawalKey = keccak256(abi.encodePacked(receiver, owner))`
  - `PendingWithdrawal` fields:
    - `owner`: owner of shares being redeemed
    - `assets`: requested asset amount
    - `shares`: shares intended to be burned
    - `fee`: fee amount in assets (yield-only fee)
    - `completed`: completion flag

**Gotcha**: because the key is `(owner, receiver)`, you can only have **one in-flight withdrawal** per pair at a time. A second withdraw attempt for the same pair will revert with `WithdrawalPending()` until the first completes.

---

## How `totalAssets()` is computed

`totalAssets()` includes:

- **Idle underlying** sitting in the vault contract, plus
- **Exit-asset value** of Maple pool shares held by the vault:
  - `maplePool.balanceOf(address(this))` → `maplePool.convertToExitAssets(poolShares)`

This means the vault NAV reflects both in-pool value and any assets Maple has already sent back to the vault.

---

## Deposits (ERC-4626 `deposit`)

Deposit flow is implemented via `_deposit(...)`:

- Enforces:
  - `depositsDisabled == false`
  - `tvlCap` (if enabled)
- Pulls underlying from the user into the vault: `safeTransferFrom(caller, address(this), assets)`
- Mints ERC-4626 shares to `receiver`
- Increases `totalPrincipal` by `assets`
- Approves `syrupRouter` and calls:
  - `syrupRouter.deposit(assets, DEPOSIT_DATA)`

**Operational requirement**: the vault contract typically must be **authorized/whitelisted** by Maple to deposit through the router.

---

## Withdrawals (ERC-4626 `withdraw`)

Withdraw behavior is split into three phases:

### 1) If there is an existing pending withdrawal for `(owner, receiver)`

`_withdraw` checks `pendingWithdrawals[withdrawalKey]`:

- If pending exists and **assets have arrived** (vault has enough idle underlying):
  - Marks pending completed
  - Burns the stored `pending.shares`
  - Transfers fee (if any) to `feesWallet`
  - Transfers remaining assets to `receiver`
  - Emits `WithdrawalCompleted` and `Withdraw`
  - Deletes the pending record

- If pending exists but **assets not yet received**:
  - Reverts `WithdrawalPending()`

This means: **a second call** to `withdraw(...)` for the same `(owner, receiver)` is used as a “finalize” step once Maple has paid the vault.

### 2) If there is no pending withdrawal and the vault already has enough idle assets

If the vault’s idle balance (`IERC20(asset()).balanceOf(address(this))`) is already `>= assets`, then:

- Fee is computed (yield-only model)
- Shares are burned immediately
- Fee (if any) is transferred to `feesWallet`
- Remaining assets are transferred immediately to `receiver`
- Emits `Withdraw`

This is the “instant withdraw” path (e.g., if Maple already sent assets back or the vault has idle liquidity).

### 3) If there is no pending withdrawal and idle assets are insufficient (async path)

If idle balance `< assets`:

- Fee + principal tracking is computed first (so the math is based on pre-withdraw NAV)
- The vault calls `_requestMapleWithdrawal(assets)`:
  - Computes `sharesToRedeem = maplePool.convertToExitShares(assets)`
  - Calls `maplePool.requestRedeem(sharesToRedeem, address(this))`
    - Maple processes this asynchronously and later transfers underlying to the vault contract.
- If assets **arrive immediately** (rare on real Maple, possible in mocks):
  - completes withdrawal in the same transaction
- Otherwise:
  - stores a `PendingWithdrawal` under `(owner, receiver)`
  - emits `WithdrawalRequested(owner, receiver, assets, shares)`

**What you should expect on Sepolia**: usually the withdrawal will **not** deliver underlying immediately; you’ll see `WithdrawalRequested` and the user’s USDC balance will not change until Maple processes the queue and sends assets back to the vault.

---

## Fees (yield-only)

Fees are intended to be charged only on yield:

- If `totalAssets() > totalPrincipal`, then `totalYield = totalAssets - totalPrincipal`.
- A withdrawing user’s yield share is approximated as:
  - `userYieldShare = (shares * totalYield) / totalSupply`
- Fee in assets:
  - `feeAmount = (userYieldShare * feePercentage) / 10000`

The contract also updates `totalPrincipal` downward based on the principal portion being withdrawn.

---

## Events you’ll use while testing

- **`Deposit(caller, receiver, assets, shares)`** (ERC-4626 standard)
- **`Withdraw(caller, receiver, owner, assets, shares)`** (ERC-4626 standard)
- **`WithdrawalRequested(owner, receiver, assets, shares)`**
  - emitted when an async request is created and pending is stored
- **`WithdrawalCompleted(owner, receiver, assets, shares)`**
  - emitted when a pending withdrawal is finalized
- **`FeesCollected(feesWallet, amount)`**

---

## Common revert reasons / gotchas

- **`ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem`**:
  - owner doesn’t have enough shares, or `maxWithdraw(owner)` is 0 for that address.
- **`WithdrawalPending()`**:
  - there is already a pending withdrawal for this `(owner, receiver)` and Maple hasn’t delivered assets yet.
- **Deposit failing**:
  - vault not authorized/whitelisted for the Syrup router or pool.
- **Only one pending withdrawal per `(owner, receiver)`**:
  - if you want parallel withdrawals, vary the receiver address or implement a nonce-based keying scheme.

---

## Sepolia testing workflow (recommended)

1) **Deposit**:
   - Approve USDC to the vault
   - Call `deposit(assets, receiver)`
2) **Withdraw (request)**:
   - Call `withdraw(assets, receiver, owner)`
   - Expect `WithdrawalRequested`
3) **Wait** until Maple processes redemption (out of band)
4) **Withdraw (finalize)**:
   - Call `withdraw(assets, receiver, owner)` again
   - If the vault now holds enough idle USDC, it will transfer to receiver and emit `WithdrawalCompleted`

---

## Notes on Maple interface compatibility

This repo uses a minimal interface. Real Maple deployments may differ across pools/versions.

If you see unexpected reverts on Sepolia:

- Confirm the pool proxy address and the pool’s expected `requestRedeem` signature.
- Confirm whether the pool sends underlying to `msg.sender` (the vault) vs a receiver argument (other Maple versions).

