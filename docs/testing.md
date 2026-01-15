# Testing

This repo supports:

- **Local unit tests**: Hardhat
- **Hardhat compilation**: produces `artifacts-hardhat/`
- **Sepolia smoke scripts**: deposit/withdraw against deployed contracts

## Local tests (Hardhat)

```bash
npm install
npm test
```

## Compile artifacts for Node scripts

```bash
npm run compile
```

This writes `artifacts-hardhat/...` used by `scripts/*-sepolia.js`.

## Hardhat

```bash
npx hardhat compile
```

## Sepolia smoke testing (Maple/Syrup vault)

1) Deposit (must have USDC and approvals):

```bash
npm run deposit:sepolia
```

2) Withdraw (Maple/Syrup is typically queued):

```bash
npm run withdraw:sepolia
```

### Important: async withdrawals

Depending on the Maple/Syrup pool behavior, `withdraw(...)` may:

- emit an on-chain event indicating the withdrawal was **requested/queued**, and
- **not** increase the receiver’s USDC balance immediately

Operationally, users may need to call withdraw again later (or otherwise “finalize”) once the pool sends assets back.

See [`docs/MapleVaultAuthorized.md`](docs/MapleVaultAuthorized.md) for the vault’s withdrawal lifecycle.

