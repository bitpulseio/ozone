const fs = require("fs");
const path = require("path");
const solc = require("solc");

function findImports(importPath) {
  // Support OpenZeppelin imports from node_modules
  if (importPath.startsWith("@openzeppelin/")) {
    const resolved = path.join(__dirname, "..", "node_modules", importPath);
    if (fs.existsSync(resolved)) {
      return { contents: fs.readFileSync(resolved, "utf8") };
    }
    return { error: `Import not found: ${importPath} -> ${resolved}` };
  }

  // Support local relative imports
  const localResolved = path.join(__dirname, "..", importPath);
  if (fs.existsSync(localResolved)) {
    return { contents: fs.readFileSync(localResolved, "utf8") };
  }

  return { error: `Import not found: ${importPath}` };
}

function compile(contractPath) {
  const abs = path.join(__dirname, "..", contractPath);
  const source = fs.readFileSync(abs, "utf8");

  const input = {
    language: "Solidity",
    sources: {
      [contractPath]: { content: source },
    },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: {
        "*": {
          "*": ["abi", "evm.bytecode", "evm.deployedBytecode"],
        },
      },
    },
  };

  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

  if (output.errors?.length) {
    const fatal = output.errors.filter((e) => e.severity === "error");
    for (const e of output.errors) {
      // eslint-disable-next-line no-console
      console.log(`${e.severity.toUpperCase()}: ${e.formattedMessage}`);
    }
    if (fatal.length) process.exit(1);
  }

  const fileContracts = output.contracts?.[contractPath];
  if (!fileContracts) throw new Error(`No contracts compiled for ${contractPath}`);

  const artifactsDir = path.join(__dirname, "..", "artifacts");
  if (!fs.existsSync(artifactsDir)) fs.mkdirSync(artifactsDir);

  for (const [name, artifact] of Object.entries(fileContracts)) {
    const outPath = path.join(artifactsDir, `${name}.json`);
    fs.writeFileSync(
      outPath,
      JSON.stringify(
        {
          contractName: name,
          abi: artifact.abi,
          bytecode: artifact.evm.bytecode.object,
        },
        null,
        2
      )
    );
    // eslint-disable-next-line no-console
    console.log(`Wrote ${outPath}`);
  }
}

// Default compile target
compile("MapleVaultAuthorized.sol");


