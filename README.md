# 🌍 Bitpulse Ozone Layer — MVP (Sepolia Testnet)

**A simplified, composable risk layer for DeFi.**  
Bitpulse Ozone connects users to leading DeFi protocols like AAVE and Uniswap through minimal ERC-4626 vaults, continuously monitored off-chain by Bitpulse’s risk engine.

---

## Overview

The Bitpulse Ozone Layer provides a **risk-underwritten gateway** to decentralized trading and lending pools.  
Each supported protocol (AAVE, Uniswap, Curve, etc.) is wrapped in a lightweight **Vault Interface (AVI)** — a minimal ERC-4626 contract that forwards deposits and withdrawals directly to the underlying protocol.

All aggregation, analytics, and risk evaluation occur **off-chain** in Bitpulse’s backend services, powering a unified portfolio dashboard and real-time monitoring.

### Core Design Principles
- **Minimal On-Chain Logic** – single-purpose, auditable contracts per protocol.  
- **Always-Open Withdrawals** – no custody; users always control their funds.  
- **Off-Chain Intelligence** – analytics, risk scoring, and alerts handled in backend.  
- **Composability** – ERC-4626 standard for seamless DeFi integrations.

---

## System Architecture

| Layer | Description |
|-------|--------------|
| **User Wallet (EOA)** | Interacts via (https://testnet.bitpulse.io) |
| **Vault Contracts (AVI / ERC-4626)** | Lightweight pass-through wrappers for each DeFi protocol |
| **Target Protocols** | AAVE v3, Uniswap v2, Curve |
| **Admin Multisig (2-of-3)** | Controls upgrades, caps, and circuit breaker |
| **Subgraph / Indexer** | Reads and indexes vault events for analytics and UI |
| **Aggregator & Risk Engine** | Off-chain analytics: APY, TVL, liquidity, risk grades |
| **Alerts Service** | Sends notifications via Email, Telegram, or Webhooks |

📄 See the full system diagram in `docs/architecture/bp1.drawio-v1.pdf`.

---

## Sepolia Testnet Deployments

| Contract | Address | Description |
|-----------|----------|-------------|
| **AVIVault — bpLINK** | [`0xC730c9C1089D39f0A95FCE6B6508317b9fb4c4Db`](https://sepolia.etherscan.io/address/0xC730c9C1089D39f0A95FCE6B6508317b9fb4c4Db) | AAVE v3 vault for LINK |
| **AVIVault — bpWBTC** | [`0x183edACd4eD97695f8800D8149abA60119FBB7BD`](https://sepolia.etherscan.io/address/0x183edACd4eD97695f8800D8149abA60119FBB7BD) | AAVE v3 vault for WBTC |
| **AVIVault — bpETH** | [`0x6a02D5C10E8204bc0ceA01Bc1B9A1359175cC7Ae`](https://sepolia.etherscan.io/address/0x6a02D5C10E8204bc0ceA01Bc1B9A1359175cC7Ae) | AAVE v3 vault for ETH |
| **Bitpulse Safe (Multisig)** | [`0x11DBA0E94E62e48471E119d9c1ceC5dF7800970e`](https://sepolia.etherscan.io/address/0x11DBA0E94E62e48471E119d9c1ceC5dF7800970e) | Fee collection and admin control |

Each vault mints **Bitpulse claim tokens** (e.g., `bpLINK`, `bpWBTC`, `bpETH`) representing ownership of the assets supplied into AAVE.

---

## Contract Features

### Vault Flow
1. **Deposit** → User deposits assets → supplied to AAVE → vault mints ERC-4626 shares.  
2. **Accrual** → Vault `totalAssets()` grows automatically as AAVE interest accrues.  
3. **Redeem** → User redeems shares → vault withdraws from AAVE → returns tokens.

### Admin Controls
- `setCap()` — maximum TVL limit per vault  
- `setDepositsDisabled()` — disable deposits (withdrawals always available)  
- **Upgradeable Proxy** — UUPS with 48-hour timelock, 2-of-3 multisig

### Security
- Reentrancy guard  
- Hard/soft TVL caps  
- No custody risk  
- Withdraw path always on-chain  
- Audit-ready minimal footprint

---

## Off-Chain Intelligence

Bitpulse services monitor all vaults via an indexed subgraph, computing:
- Real-time TVL, APY, and utilization  
- Liquidity risk and reserve health  
- A–D risk grades  
- Alerts when markets pause, caps are reached, or volatility spikes  

**Notifications** are sent via Email, Telegram, or Webhooks.  
Access to premium analytics requires holding the `$BP` token (coming soon).

---

## Getting Started (Testnet)

1. Connect wallet to **Sepolia** on (https://testnet.bitpulse.io)  
2. Select any active AAVE vault (e.g., bpLINK, bpWBTC)  
3. Deposit test tokens → receive `bp` claim tokens  
4. Watch your balance grow with AAVE yield  
5. Withdraw anytime — fully non-custodial  

---

## Roadmap

| Phase | Focus |
|-------|-------|
| **MVP (Now)** | AAVE vaults live on Sepolia |
| **Phase 2** | Subgraph monitoring + ERC-1155 multi-vault claims, incentives, Base/Arbitrum support |
| **Phase 3** | `$PULSE` governance + fee routing and risk staking |

---

## License

MIT License © 2025 **Bitpulse Inc.**  
Contracts are deployed on **Sepolia testnet** for public testing and audit review.

---

### References
- [ERC-4626 Standard](https://docs.openzeppelin.com/contracts/4.x/erc4626)  
- [AAVE v3 Documentation](https://docs.aave.com/)  
- [The Graph Protocol](https://thegraph.com)  
- [Bitpulse Architecture Diagram](./docs/architecture/bp1.drawio-v1.pdf)

---

**Bitpulse Ozone Layer — Simplifying DeFi risk, one vault at a time.**
