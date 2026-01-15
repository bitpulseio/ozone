require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

function mustEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

async function main() {
  const rpcUrl = mustEnv("SEPOLIA_RPC_URL");
  const pk = mustEnv("SEPOLIA_PRIVATE_KEY");

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(pk, provider);

  const deployer = await wallet.getAddress();
  const bal = await provider.getBalance(deployer);
  console.log(`Deployer: ${deployer}`);
  console.log(`Balance:  ${ethers.formatEther(bal)} ETH`);

  const usdc = mustEnv("SEPOLIA_USDC");
  const syrupRouter = mustEnv("SEPOLIA_SYRUP_ROUTER");
  const poolV2 = mustEnv("SEPOLIA_POOLV2"); // PoolV2 is also the syrup share token
  const feesWallet = mustEnv("FEES_WALLET");
  const feeBps = BigInt(process.env.FEE_BPS || "100");
  const assetSymbol = process.env.ASSET_SYMBOL || "USDC";

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

  // Constructor args:
  // (IERC20 underlying, address _maplePool, address _syrupRouter, address _syrupToken, address _feesWallet, uint256 _feePercentage, string assetSymbol)
  // For Syrup pools: _maplePool == _syrupToken == PoolV2 address
  const args = [usdc, poolV2, syrupRouter, poolV2, feesWallet, feeBps, assetSymbol];

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const contract = await factory.deploy(...args);
  console.log(`Deploy tx: ${contract.deploymentTransaction().hash}`);
  await contract.waitForDeployment();
  const addr = await contract.getAddress();

  console.log(`Deployed MapleVault (MapleVault) at: ${addr}`);
  console.log("To verify with Hardhat:");
  console.log(`npx hardhat verify --network sepolia ${addr} ${args.join(" ")}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});


