# Architecture

This repo provides **ERC-4626 vault contracts** that forward deposits into third-party protocols (e.g., Aave, Maple/Syrup) with minimal on-chain logic.

## Components

- **User (EOA)**: holds underlying assets and vault shares.
- **Vault (ERC-4626)**: mints shares on deposit; burns shares on withdraw/redeem.
- **Protocol integration**:
  - **Aave v3**: `supply` on deposit, `withdraw` on withdrawal.
  - **Maple/Syrup**: deposits via Syrup router; withdrawals via **queued redemptions** (`requestRedeem`), which are typically **asynchronous**.
- **Admin**:
  - Per-vault owner (`Ownable2Step`) controls caps and the deposit circuit breaker.

## Trust boundaries

- The vaults are thin wrappers. **Protocol risk is external**:
  - If Aave/Maple misbehave, pause, or are exploited, the vault is impacted.
- Vault admin powers are intentionally limited to **depositsDisabled** and **tvlCap** (no ability to seize user funds).

## Core flows

```mermaid
flowchart TD
  User[User] -->|"deposit(assets,receiver)"| Vault[MapleVault_ERC4626]
  Vault -->|"router.deposit(...)"| SyrupRouter[SyrupRouter]
  SyrupRouter -->|deposit_into| MaplePool[MaplePool]

  User -->|"withdraw(assets,receiver,owner)"| Vault
  Vault -->|"requestRedeem(sharesToRedeem)"| MaplePool
  MaplePool -->|async_transfer_assets| Vault
  User -->|withdraw_again_to_finalize| Vault
  Vault -->|transfer_assets_minus_fee| User
```

For contract-specific details see:

- Maple: [`docs/MapleVaultAuthorized.md`](docs/MapleVaultAuthorized.md)

