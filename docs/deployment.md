# Deployment guide

This repo supports deployment and smoke-testing via **Node scripts** (and compilation via Hardhat/Foundry).

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

The Node scripts use the `artifacts/` JSON written by:

```bash
npm run compile
```

## Deploy (Sepolia)

```bash
npm run deploy:sepolia
```

This deploy script expects `artifacts/MapleVault.json` and will print the deployed address.

## Verify (optional)

Set:

- `ETHERSCAN_API_KEY`
- `VERIFY_ON_ETHERSCAN=true`

Then deploy again (the deploy script will auto-verify).

## Operational notes

- Aave vaults are synchronous (withdraw returns assets immediately if the protocol has liquidity).
- Maple/Syrup withdrawals are typically **asynchronous**; see [`docs/testing.md`](docs/testing.md).

