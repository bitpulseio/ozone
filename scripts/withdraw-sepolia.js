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
];

function asAddress(name, v) {
  try {
    return ethers.getAddress(v);
  } catch {
    throw new Error(`Invalid address for ${name}: ${v}`);
  }
}

function dumpRevert(e) {
  console.error("Revert / call exception details:");
  console.error("shortMessage:", e?.shortMessage);
  console.error("reason:", e?.reason);
  console.error("code:", e?.code);
  console.error("data:", e?.data);
  console.error("info.error:", e?.info?.error);
}

function findEvent(rcpt, iface, name) {
  const out = [];
  for (const log of rcpt.logs || []) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed?.name === name) out.push(parsed);
    } catch {
      // ignore
    }
  }
  return out;
}

async function main() {
  const rpcUrl = mustEnv("SEPOLIA_RPC_URL");
  const pk = mustEnv("SEPOLIA_PRIVATE_KEY");
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(pk, provider);

  const signer = asAddress("signer", await wallet.getAddress());
  const vaultAddr = asAddress("SEPOLIA_VAULT", mustEnv("SEPOLIA_VAULT"));
  console.log(`Signer:  ${signer}`);
  console.log(`Vault:   ${vaultAddr}`);

  const usdcAddr = asAddress("SEPOLIA_USDC", mustEnv("SEPOLIA_USDC"));
  const usdc = new ethers.Contract(usdcAddr, ERC20_ABI, wallet);
  const decimals = await usdc.decimals();

  const amountStr = mustEnv("WITHDRAW_AMOUNT"); // e.g. "1.0"
  const assets = ethers.parseUnits(amountStr, decimals);

  // Receiver of underlying (Maple will pay asynchronously when processed)
  const receiverEnv = (process.env.WITHDRAW_RECEIVER || "").trim();
  let receiver = receiverEnv ? asAddress("WITHDRAW_RECEIVER", receiverEnv) : signer;
  // Owner of vault shares being burned (must be signer unless you've approved allowance)
  const ownerEnv = (process.env.WITHDRAW_OWNER || "").trim();
  let owner = ownerEnv ? asAddress("WITHDRAW_OWNER", ownerEnv) : signer;
  const forceSend = (process.env.WITHDRAW_FORCE_SEND || "").toLowerCase() === "true";

  // Hard safety: never allow "owner" to equal the vault contract address (this is the exact footgun you hit)
  if (owner.toLowerCase() === vaultAddr.toLowerCase()) {
    console.warn(
      `WARNING: WITHDRAW_OWNER is set to the vault address (${vaultAddr}). This will always fail unless the vault itself holds shares. Falling back to signer (${signer}).`
    );
    owner = signer;
  }
  // Similarly, if receiver was accidentally set to the vault address, default to signer
  if (receiver.toLowerCase() === vaultAddr.toLowerCase()) {
    console.warn(
      `WARNING: WITHDRAW_RECEIVER is set to the vault address (${vaultAddr}). Falling back to signer (${signer}).`
    );
    receiver = signer;
  }

  const artifactPath = path.join(
    __dirname,
    "..",
    "artifacts-hardhat",
    "contracts",
    "vaults",
    "maple",
    "MapleVault.sol",
    "MapleVault.json"
  );
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const vault = new ethers.Contract(vaultAddr, artifact.abi, wallet);

  // ABI sanity checks (prevents sending a blank-data tx)
  if (typeof vault.withdraw !== "function") {
    throw new Error(
      "Artifact ABI missing `withdraw(...)`. Run `npx hardhat compile` and ensure artifacts-hardhat has MapleVault.json."
    );
  }
  if (typeof vault.maxWithdraw !== "function" || typeof vault.maxRedeem !== "function") {
    throw new Error(
      "Artifact ABI missing ERC4626 view methods (maxWithdraw/maxRedeem). Run `npx hardhat compile`."
    );
  }

  const usdcBefore = await usdc.balanceOf(receiver);
  const sharesBefore = await vault.balanceOf(owner);
  console.log(`Receiver USDC before: ${ethers.formatUnits(usdcBefore, decimals)}`);
  console.log(`Owner vault shares:   ${sharesBefore.toString()}`);
  console.log(`Using owner:          ${owner}`);
  console.log(`Using receiver:       ${receiver}`);

  // ERC4626 guardrails: check maxWithdraw/maxRedeem up front so we don't pay gas for guaranteed reverts
  const maxWithdraw = await vault.maxWithdraw(owner);
  const maxRedeem = await vault.maxRedeem(owner);
  console.log(`maxWithdraw(owner):   ${ethers.formatUnits(maxWithdraw, decimals)} assets`);
  console.log(`maxRedeem(owner):     ${maxRedeem.toString()} shares`);

  if (maxWithdraw < assets && !forceSend) {
    throw new Error(
      `Refusing to broadcast: withdraw(${amountStr}) exceeds maxWithdraw(owner)=${ethers.formatUnits(
        maxWithdraw,
        decimals
      )}. Set WITHDRAW_FORCE_SEND=true to broadcast anyway (will likely revert and waste gas).`
    );
  }

  // If caller != owner, ERC4626 requires share allowance (vault shares are the ERC20 itself)
  if (owner.toLowerCase() !== signer.toLowerCase()) {
    const shareAllowance = await vault.allowance(owner, signer);
    console.log(`Share allowance owner->signer: ${shareAllowance.toString()}`);
    if (shareAllowance === 0n && !forceSend) {
      throw new Error(
        `Refusing to broadcast: owner != signer and share allowance is 0. Either set WITHDRAW_OWNER=${signer} or approve shares (vault.allowance) first.`
      );
    }
  }

  // Simulate first (no gas) to surface revert reasons
  try {
    await vault.withdraw.staticCall(assets, receiver, owner);
    console.log("staticCall: OK (withdraw would succeed)");
  } catch (e) {
    console.log("staticCall: reverted (this is the real revert reason/data):");
    dumpRevert(e);
    if (!forceSend) {
      throw new Error("Refusing to broadcast because staticCall reverted. Set WITHDRAW_FORCE_SEND=true to broadcast anyway.");
    }
  }

  // Optional: force-send without estimateGas
  const gasLimitEnv = process.env.WITHDRAW_GAS_LIMIT;
  const overrides = gasLimitEnv ? { gasLimit: BigInt(gasLimitEnv) } : undefined;

  console.log(`Withdrawing ${amountStr} assets to receiver=${receiver} owner=${owner}...`);
  try {
    const tx = overrides
      ? await vault.withdraw(assets, receiver, owner, overrides)
      : await vault.withdraw(assets, receiver, owner);
    console.log(`Withdraw tx: ${tx.hash}`);
    const rcpt = await tx.wait();
    console.log(`Withdraw receipt status=${rcpt.status} block=${rcpt.blockNumber}`);

    // Parse key events to confirm queueing
    const iface = vault.interface;
    const requested = findEvent(rcpt, iface, "WithdrawalRequested");
    const withdrew = findEvent(rcpt, iface, "Withdraw");
    console.log(`Events: WithdrawalRequested=${requested.length} Withdraw=${withdrew.length}`);
    if (requested.length) {
      for (const ev of requested) {
        // (receiver, requestedAssets, requestedPoolShares)
        console.log(
          `- WithdrawalRequested receiver=${ev.args.receiver} assets=${ev.args.requestedAssets.toString()} poolShares=${ev.args.requestedPoolShares.toString()}`
        );
      }
    }

    const usdcAfter = await usdc.balanceOf(receiver);
    console.log(`Receiver USDC after:  ${ethers.formatUnits(usdcAfter, decimals)}`);
    console.log(
      "Note: Maple/Syrup withdrawals are queued; receiver USDC may not change until Maple processes the redemption."
    );
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


