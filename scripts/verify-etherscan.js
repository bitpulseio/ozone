require("dotenv").config();
const fs = require("fs");
const path = require("path");
const solc = require("solc");
const { ethers } = require("ethers");

function mustEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function resolveImport(importPath) {
  if (importPath.startsWith("@openzeppelin/")) {
    return path.join(__dirname, "..", "node_modules", importPath);
  }
  return path.join(__dirname, "..", importPath);
}

function collectSources(entry) {
  const sources = {};
  const seen = new Set();

  const rootDir = path.join(__dirname, "..");
  const toPosix = (p) => p.split(path.sep).join(path.posix.sep);

  function keyForAbs(absPath, preferredKey) {
    // Preserve OZ module specifiers as-is for stable keys
    if (preferredKey && preferredKey.startsWith("@openzeppelin/")) return preferredKey;

    // If this file lives under node_modules/@openzeppelin, key it as @openzeppelin/...
    const ozRoot = path.join(rootDir, "node_modules", "@openzeppelin");
    if (absPath.startsWith(ozRoot + path.sep) || absPath === ozRoot) {
      const relFromOz = path.relative(path.join(rootDir, "node_modules"), absPath);
      return toPosix(relFromOz);
    }
    // Otherwise key by project-relative path (posix)
    const rel = path.relative(rootDir, absPath);
    return toPosix(rel);
  }

  function resolveAbs(fromAbs, importSpec) {
    if (importSpec.startsWith("@openzeppelin/")) {
      return resolveImport(importSpec);
    }

    // Relative import: resolve from the importing file's directory
    if (importSpec.startsWith("./") || importSpec.startsWith("../")) {
      if (!fromAbs) throw new Error(`Relative import without base: ${importSpec}`);
      return path.resolve(path.dirname(fromAbs), importSpec);
    }

    // Project-local absolute-ish import: resolve from repo root
    return resolveImport(importSpec);
  }

  function addSource(fromAbs, importSpec) {
    const abs = resolveAbs(fromAbs, importSpec);
    if (!fs.existsSync(abs)) throw new Error(`Missing import on disk: ${importSpec} -> ${abs}`);

    const key = keyForAbs(abs, importSpec);
    if (seen.has(key)) return;
    seen.add(key);

    const content = fs.readFileSync(abs, "utf8");
    sources[key] = { content };

    const re = /import\s+(?:[^'"]+\s+from\s+)?["']([^"']+)["'];/g;
    let m;
    while ((m = re.exec(content))) {
      addSource(abs, m[1]);
    }
  }

  // Entry is relative to repo root
  addSource(null, entry);
  return sources;
}

function buildStandardJsonInput() {
  const entry = "MapleVaultAuthorized.sol";
  const sources = collectSources(entry);

  return {
    language: "Solidity",
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      // Keep this minimal; Etherscan will compile internally
      outputSelection: {
        "*": { "*": [] },
      },
    },
  };
}

function encodeConstructorArgs(args) {
  // constructor(IERC20 underlying, address _maplePool, address _syrupRouter, address _syrupToken, address _feesWallet, uint256 _feePercentage, string assetSymbol)
  const types = ["address", "address", "address", "address", "address", "uint256", "string"];
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(types, args);
  return encoded.startsWith("0x") ? encoded.slice(2) : encoded;
}

async function etherscanPost(params) {
  // Etherscan API v2 requires chainid and uses a single base URL.
  // Sepolia chainId = 11155111
  const url = "https://api.etherscan.io/v2/api?chainid=11155111";
  const body = new URLSearchParams(params);
  const res = await fetch(url, { method: "POST", body });
  const json = await res.json();
  return json;
}

async function verifyOnEtherscan({ contractAddress, constructorArgs }) {
  const apiKey = mustEnv("ETHERSCAN_API_KEY");

  // Use solc-js version string to match compilerversion format Etherscan expects.
  // Example: 0.8.24+commit.e11b9ed9 -> v0.8.24+commit.e11b9ed9
  const rawSolc = solc.version();
  const m = rawSolc.match(/^(\d+\.\d+\.\d+\+commit\.[0-9a-fA-F]+)/);
  const compilerVersion = `v${m ? m[1] : rawSolc}`;

  const stdJson = buildStandardJsonInput();
  const sourceCode = JSON.stringify(stdJson);

  const contractName = "MapleVaultAuthorized.sol:MapleVault";

  const submit = await etherscanPost({
    apikey: apiKey,
    module: "contract",
    action: "verifysourcecode",
    contractaddress: contractAddress,
    sourceCode,
    codeformat: "solidity-standard-json-input",
    contractname: contractName,
    compilerversion: compilerVersion,
    optimizationUsed: "1",
    runs: "200",
    constructorArguements: encodeConstructorArgs(constructorArgs),
    licenseType: "3", // MIT
  });

  if (submit.status !== "1") {
    throw new Error(`Etherscan submit failed: ${submit.message} ${submit.result}`);
  }

  const guid = submit.result;
  console.log(`Etherscan GUID: ${guid}`);

  // Poll
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const check = await etherscanPost({
      apikey: apiKey,
      module: "contract",
      action: "checkverifystatus",
      guid,
    });

    if (check.status === "1") {
      console.log(`Verified: ${check.result}`);
      return;
    }
    if (typeof check.result === "string" && check.result.toLowerCase().includes("fail")) {
      throw new Error(`Verification failed: ${check.result}`);
    }
    console.log(`Verify status: ${check.result}`);
  }

  throw new Error("Verification timed out (Etherscan still processing)");
}

// CLI mode:
// node scripts/verify-etherscan.js <contractAddress>
if (require.main === module) {
  const addr = process.argv[2];
  if (!addr) {
    console.error("Usage: node scripts/verify-etherscan.js <contractAddress>");
    process.exit(1);
  }

  const usdc = mustEnv("SEPOLIA_USDC");
  const syrupRouter = mustEnv("SEPOLIA_SYRUP_ROUTER");
  const poolV2 = mustEnv("SEPOLIA_POOLV2");
  const feesWallet = mustEnv("FEES_WALLET");
  const feeBps = BigInt(process.env.FEE_BPS || "100");
  const assetSymbol = process.env.ASSET_SYMBOL || "USDC";

  const args = [usdc, poolV2, syrupRouter, poolV2, feesWallet, feeBps, assetSymbol];

  verifyOnEtherscan({ contractAddress: addr, constructorArgs: args }).catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { verifyOnEtherscan };


