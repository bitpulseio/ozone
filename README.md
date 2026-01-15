# Bitpulse Ozone — ERC-4626 vaults for DeFi protocols

Bitpulse Ozone is a small set of **ERC-4626 vaults** that route deposits into third-party protocols (e.g., Aave, Maple/Syrup) while keeping on-chain logic minimal and auditable.

This repo is **MVP-stage** but **mainnet-intended**: it includes an explicit threat model, invariants, and reproducible build/test flows for Hardhat users.

## Quick links

- **Docs index**: see [`docs/`](docs/)
  - Architecture: [`docs/architecture.md`](docs/architecture.md)
  - Threat model: [`docs/threat-model.md`](docs/threat-model.md)
  - Invariants: [`docs/invariants.md`](docs/invariants.md)
  - Deployment: [`docs/deployment.md`](docs/deployment.md)
  - Testing: [`docs/testing.md`](docs/testing.md)
  - Maple vault deep-dive: [`docs/MapleVaultAuthorized.md`](docs/MapleVaultAuthorized.md)

## Repo map (what lives where)

- **Production contracts**: [`contracts/`](contracts/)
  - Aave vaults: [`contracts/vaults/aave/`](contracts/vaults/aave/)
  - Maple/Syrup vault: [`contracts/vaults/maple/`](contracts/vaults/maple/)
- **Mocks** (tests only): [`contracts/mocks/`](contracts/mocks/)
- **Node scripts** (Sepolia smoke tests): [`scripts/`](scripts/)
- **Tests** (Hardhat): [`test/`](test/)
- **Docs**: [`docs/`](docs/)

## Getting started

### Hardhat (compile + test)

```bash
npm install
npm run compile
npm test
```

### Sepolia smoke scripts (Node)

Copy the env template and fill it in:

```bash
cp SEPOLIA_ENV_TEMPLATE.txt .env
```

Then run:

```bash
npm run deploy:sepolia
npm run deposit:sepolia
npm run withdraw:sepolia
```

Notes:
- Maple/Syrup withdrawals are typically **queued/asynchronous**. `withdraw` may emit `WithdrawalRequested` without an immediate USDC balance increase. See [`docs/testing.md`](docs/testing.md).

Hardhat artifacts are written to `artifacts-hardhat/`.

## Sepolia deployments

This repo contains deployment scripts and a template for the known Sepolia addresses in `SEPOLIA_ENV_TEMPLATE.txt`.

## Security + audit posture

- **Threat model**: [`docs/threat-model.md`](docs/threat-model.md)
- **Explicit invariants**: [`docs/invariants.md`](docs/invariants.md)
- **External dependencies**: Aave / Maple contracts are out of scope for this repo’s correctness; we treat them as trusted-but-risky dependencies and document assumptions.

## License

MIT
