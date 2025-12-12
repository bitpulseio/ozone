require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

function mustEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 value) returns (bool)",
];

function dumpRevert(e) {
  console.error("Revert / call exception details:");
  console.error("shortMessage:", e?.shortMessage);
  console.error("reason:", e?.reason);
  console.error("code:", e?.code);
  // ethers v6 sometimes nests revert data here:
  console.error("data:", e?.data);
  console.error("info.error:", e?.info?.error);
}

async function main() {
  const rpcUrl = mustEnv("SEPOLIA_RPC_URL");
  const pk = mustEnv("SEPOLIA_PRIVATE_KEY");
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(pk, provider);

  const deployer = await wallet.getAddress();
  console.log(`Signer:  ${deployer}`);
  console.log(`Vault:   ${mustEnv("SEPOLIA_VAULT")}`);

  const usdcAddr = mustEnv("SEPOLIA_USDC");
  const vaultAddr = mustEnv("SEPOLIA_VAULT");
  const receiver = process.env.DEPOSIT_RECEIVER || deployer;

  const usdc = new ethers.Contract(usdcAddr, ERC20_ABI, wallet);
  const decimals = await usdc.decimals();

  const amountStr = mustEnv("DEPOSIT_AMOUNT"); // e.g. "1.0"
  const amount = ethers.parseUnits(amountStr, decimals);

  const bal = await usdc.balanceOf(deployer);
  console.log(`USDC balance: ${ethers.formatUnits(bal, decimals)}`);
  if (bal < amount) {
    throw new Error(`Insufficient USDC. Need ${amountStr}, have ${ethers.formatUnits(bal, decimals)}`);
  }

  const artifactPath = path.join(__dirname, "..", "artifacts", "MapleVault.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const vault = new ethers.Contract(vaultAddr, artifact.abi, wallet);

  // Basic sanity checks
  const disabled = await vault.depositsDisabled();
  if (disabled) throw new Error("Vault deposits are disabled (depositsDisabled=true)");

  const max = await vault.maxDeposit(receiver);
  if (max < amount) {
    throw new Error(
      `Deposit exceeds maxDeposit. max=${ethers.formatUnits(max, decimals)} requested=${amountStr}`
    );
  }

  // Approve if needed
  const allowance = await usdc.allowance(deployer, vaultAddr);
  if (allowance < amount) {
    console.log(`Approving USDC -> vault for ${amountStr}...`);
    const tx = await usdc.approve(vaultAddr, amount);
    console.log(`Approve tx: ${tx.hash}`);
    await tx.wait();
  } else {
    console.log("Allowance sufficient, skipping approve.");
  }

  console.log(`Depositing ${amountStr} to receiver=${receiver}...`);

  // 1) Simulate first to surface Maple/SyrupRouter revert data (no gas spent)
  try {
    await vault.deposit.staticCall(amount, receiver);
    console.log("staticCall: OK (deposit would succeed)");
  } catch (e) {
    console.log("staticCall: reverted (this is the real revert reason/data):");
    dumpRevert(e);
  }

  // 2) Optionally broadcast even if estimateGas fails (it may revert on-chain, but tx will be mined)
  // Set DEPOSIT_GAS_LIMIT to force-send without estimateGas, e.g. 2500000
  const gasLimitEnv = process.env.DEPOSIT_GAS_LIMIT;
  const overrides = gasLimitEnv ? { gasLimit: BigInt(gasLimitEnv) } : undefined;

  try {
    const tx2 = overrides ? await vault.deposit(amount, receiver, overrides) : await vault.deposit(amount, receiver);
    console.log(`Deposit tx: ${tx2.hash}`);
    const rcpt = await tx2.wait();
    console.log(`Deposit receipt status=${rcpt.status} block=${rcpt.blockNumber}`);
  } catch (e) {
    console.log("Broadcast failed / reverted:");
    dumpRevert(e);
    throw e;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});


