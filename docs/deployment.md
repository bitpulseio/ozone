# Deployment guide

This repo supports deployment and smoke-testing via **Node scripts** (compiled via Hardhat).

## Environment

Use `SEPOLIA_ENV_TEMPLATE.txt` as a starting point:

- `SEPOLIA_RPC_URL`
- `SEPOLIA_PRIVATE_KEY`
- `SEPOLIA_VAULT` (if interacting with an existing vault)

Maple/Syrup (Sepolia) addresses used by scripts:

- `SEPOLIA_USDC`
- `SEPOLIA_SYRUP_ROUTER`
- `SEPOLIA_POOLV2`

Vault config:

- `FEES_WALLET`
- `FEE_BPS`
- `ASSET_SYMBOL`

## Compile artifacts (Node scripts)

The Node scripts use the `artifacts-hardhat/` JSON written by:

```bash
npm run compile
```

## Deploy (Sepolia)

```bash
npm run deploy:sepolia
```

This deploy script expects the Hardhat artifact at:
`artifacts-hardhat/contracts/vaults/maple/MapleVault.sol/MapleVault.json`

## Verify (optional)

Use Hardhat's verifier:

```bash
npx hardhat verify --network sepolia <deployed_address> <constructor_args...>
```

## Operational notes

- Aave vaults are synchronous (withdraw returns assets immediately if the protocol has liquidity).
- Maple/Syrup withdrawals are typically **asynchronous**; see [`docs/testing.md`](docs/testing.md).

