const assert = require("assert");
const path = require("path");
const fs = require("fs");
const ganache = require("ganache");
const { ethers } = require("ethers");
const solc = require("solc");

function findImports(importPath) {
  if (importPath.startsWith("@openzeppelin/")) {
    const resolved = path.join(__dirname, "..", "node_modules", importPath);
    if (fs.existsSync(resolved)) return { contents: fs.readFileSync(resolved, "utf8") };
    return { error: `Import not found: ${importPath}` };
  }
  const local1 = path.join(__dirname, "..", importPath);
  if (fs.existsSync(local1)) return { contents: fs.readFileSync(local1, "utf8") };
  const local2 = path.join(__dirname, "..", "contracts", importPath);
  if (fs.existsSync(local2)) return { contents: fs.readFileSync(local2, "utf8") };
  return { error: `Import not found: ${importPath}` };
}

function compileAll() {
  const sources = {};
  const add = (p) => {
    sources[p] = { content: fs.readFileSync(path.join(__dirname, "..", p), "utf8") };
  };

  add("MapleVaultAuthorized.sol");
  add("contracts/mocks/MockERC20.sol");
  add("contracts/mocks/MockPoolV2.sol");
  add("contracts/mocks/MockSyrupRouter.sol");

  const input = {
    language: "Solidity",
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: { "*": { "*": ["abi", "evm.bytecode"] } },
    },
  };

  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
  if (output.errors?.length) {
    const fatal = output.errors.filter((e) => e.severity === "error");
    for (const e of output.errors) console.log(`${e.severity.toUpperCase()}: ${e.formattedMessage}`);
    if (fatal.length) throw new Error("Compilation failed");
  }
  return output.contracts;
}

async function deploy(contracts, file, name, signer, args = []) {
  const c = contracts[file][name];
  const factory = new ethers.ContractFactory(c.abi, c.evm.bytecode.object, signer);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

describe("MapleVaultAuthorized (local simulation)", function () {
  this.timeout(60000);

  let provider, accounts, signer0, signer1, signer2;
  let contracts;

  before(async () => {
    contracts = compileAll();
    provider = new ethers.BrowserProvider(
      ganache.provider({
        wallet: { totalAccounts: 5, defaultBalance: 1_000 },
        chain: { chainId: 1337 },
        logging: { quiet: true },
      })
    );
    accounts = await provider.listAccounts();
    signer0 = await provider.getSigner(accounts[0].address);
    signer1 = await provider.getSigner(accounts[1].address);
    signer2 = await provider.getSigner(accounts[2].address);
  });

  it("deposit mints vault shares and deposits into PoolV2 via router", async () => {
    const usdc = await deploy(contracts, "contracts/mocks/MockERC20.sol", "MockERC20", signer0, [
      "Mock USDC",
      "mUSDC",
      6,
    ]);

    const pool = await deploy(contracts, "contracts/mocks/MockPoolV2.sol", "MockPoolV2", signer0, [
      await usdc.getAddress(),
      "Mock PoolV2",
      "mPOOL",
    ]);

    const router = await deploy(contracts, "contracts/mocks/MockSyrupRouter.sol", "MockSyrupRouter", signer0, [
      await usdc.getAddress(),
    ]);

    // mint underlying to user
    await (await usdc.mint(accounts[1].address, 1_000_000)).wait(); // 1 USDC (6 decimals) style amount for mock

    // deploy vault (note: _maplePool and _syrupToken must match)
    const vault = await deploy(contracts, "MapleVaultAuthorized.sol", "MapleVault", signer0, [
      await usdc.getAddress(),
      await pool.getAddress(),
      await router.getAddress(),
      await pool.getAddress(),
      accounts[0].address,
      100,
      "USDC",
    ]);

    // approve vault to pull underlying
    await (await usdc.connect(signer1).approve(await vault.getAddress(), 500_000)).wait();

    // deposit 0.5 "USDC" units in mock units
    await (await vault.connect(signer1).deposit(500_000, accounts[1].address)).wait();

    const userShares = await vault.balanceOf(accounts[1].address);
    assert.equal(userShares.toString(), "500000");

    // vault should have pool shares after router deposit
    const vaultPoolShares = await pool.balanceOf(await vault.getAddress());
    assert.equal(vaultPoolShares.toString(), "500000");
  });

  it("withdraw requests redeem to receiver and does not send underlying via vault", async () => {
    const usdc = await deploy(contracts, "contracts/mocks/MockERC20.sol", "MockERC20", signer0, [
      "Mock USDC",
      "mUSDC",
      6,
    ]);

    const pool = await deploy(contracts, "contracts/mocks/MockPoolV2.sol", "MockPoolV2", signer0, [
      await usdc.getAddress(),
      "Mock PoolV2",
      "mPOOL",
    ]);

    const router = await deploy(contracts, "contracts/mocks/MockSyrupRouter.sol", "MockSyrupRouter", signer0, [
      await usdc.getAddress(),
    ]);

    // Provide underlying liquidity to pool mock so requestRedeem can transfer out
    await (await usdc.mint(await pool.getAddress(), 10_000_000)).wait();

    await (await usdc.mint(accounts[1].address, 1_000_000)).wait();

    const vault = await deploy(contracts, "MapleVaultAuthorized.sol", "MapleVault", signer0, [
      await usdc.getAddress(),
      await pool.getAddress(),
      await router.getAddress(),
      await pool.getAddress(),
      accounts[0].address,
      100,
      "USDC",
    ]);

    await (await usdc.connect(signer1).approve(await vault.getAddress(), 500_000)).wait();
    await (await vault.connect(signer1).deposit(500_000, accounts[1].address)).wait();

    const receiverBalBefore = await usdc.balanceOf(accounts[1].address);

    // Withdraw 200k assets - in this mock, it triggers requestRedeem which pays out immediately
    await (await vault.connect(signer1).withdraw(200_000, accounts[1].address, accounts[1].address)).wait();

    // user got paid (minus any fee split behavior may apply depending on vault's yield logic)
    const receiverBalAfter = await usdc.balanceOf(accounts[1].address);
    assert(receiverBalAfter > receiverBalBefore, "receiver should receive underlying from pool");

    // vault should not hold underlying (it doesn't transfer out; pool pays receiver directly)
    const vaultUnderlying = await usdc.balanceOf(await vault.getAddress());
    assert.equal(vaultUnderlying.toString(), "0");
  });

  it("can force queued (async) withdrawals: withdraw queues, then pool processes payout", async () => {
    const usdc = await deploy(contracts, "contracts/mocks/MockERC20.sol", "MockERC20", signer0, [
      "Mock USDC",
      "mUSDC",
      6,
    ]);

    const pool = await deploy(contracts, "contracts/mocks/MockPoolV2.sol", "MockPoolV2", signer0, [
      await usdc.getAddress(),
      "Mock PoolV2",
      "mPOOL",
    ]);

    const router = await deploy(contracts, "contracts/mocks/MockSyrupRouter.sol", "MockSyrupRouter", signer0, [
      await usdc.getAddress(),
    ]);

    // Enable async/queued redemptions to emulate Maple behavior
    await (await pool.setAsyncRedeem(true)).wait();

    // Provide underlying liquidity to pool mock so later processing can transfer out
    await (await usdc.mint(await pool.getAddress(), 10_000_000)).wait();
    await (await usdc.mint(accounts[1].address, 1_000_000)).wait();

    const vault = await deploy(contracts, "MapleVaultAuthorized.sol", "MapleVault", signer0, [
      await usdc.getAddress(),
      await pool.getAddress(),
      await router.getAddress(),
      await pool.getAddress(),
      accounts[0].address,
      100,
      "USDC",
    ]);

    await (await usdc.connect(signer1).approve(await vault.getAddress(), 500_000)).wait();
    await (await vault.connect(signer1).deposit(500_000, accounts[1].address)).wait();

    const receiverBalBefore = await usdc.balanceOf(accounts[1].address);

    // Withdraw queues redemption (no immediate transfer from vault; pool processing happens later)
    await (await vault.connect(signer1).withdraw(200_000, accounts[1].address, accounts[1].address)).wait();

    const receiverBalAfterWithdraw = await usdc.balanceOf(accounts[1].address);
    assert.equal(
      receiverBalAfterWithdraw.toString(),
      receiverBalBefore.toString(),
      "receiver should not receive underlying until redemption is processed"
    );

    const pending = await pool.pendingRedeemAssets(accounts[1].address);
    assert.equal(pending.toString(), "200000", "pending redemption should be queued in the pool mock");

    // Force processing payout (test hook)
    await (await pool.processRedeem(accounts[1].address)).wait();

    const receiverBalAfterProcess = await usdc.balanceOf(accounts[1].address);
    assert(receiverBalAfterProcess > receiverBalAfterWithdraw, "receiver should be paid after processing");

    const pendingAfter = await pool.pendingRedeemAssets(accounts[1].address);
    assert.equal(pendingAfter.toString(), "0", "pending redemption should be cleared after processing");
  });
});


