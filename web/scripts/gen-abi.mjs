// Regenerates lib/abi.ts from the Foundry build artifacts in ../contracts/out.
// Run with `npm run abi` after recompiling the contracts.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(here, "..", "..", "contracts", "out");
const TARGET = resolve(here, "..", "lib", "abi.ts");

function artifact(sol, name) {
  const p = join(OUT, sol, `${name}.json`);
  return JSON.parse(readFileSync(p, "utf8")).abi;
}

// Keep the shipped ABIs to what the console actually calls. Errors and events are
// kept wholesale so revert data decodes with its real name.
function trim(abi, names) {
  const wanted = new Set(names);
  return abi.filter((e) => {
    if (e.type === "error") return true;
    if (e.type === "function") return wanted.has(e.name);
    if (e.type === "event") return wanted.has(e.name);
    return false;
  });
}

// The gate surface both CreditManager and StandingPool inherit. Kept separately so a
// component can ask the same question of either contract without branching on which.
const complianceGate = trim(artifact("ComplianceGate.sol", "ComplianceGate"), [
  "credentialOf",
  "checkTransfer",
  "checkTransferDetailed",
  "checkParty",
  "isProtocolRegistered",
  "apassRegistry",
  "policy",
  "validator",
  "verifiedAsset",
  "owner",
]);

const creditManager = trim(artifact("CreditManager.sol", "CreditManager"), [
  "credentialOf",
  "checkTransfer",
  "checkTransferDetailed",
  "checkParty",
  "isProtocolRegistered",
  "validator",
  "quote",
  "open",
  "repay",
  "markDefault",
  "loan",
  "loanCount",
  "loansOfIdentity",
  "isDefaultable",
  "drawnByIdentity",
  "pool",
  "registry",
  "apassRegistry",
  "policy",
  "verifiedAsset",
  "owner",
  "maxLoanPrincipal",
  "maxCreditLine",
  "maxTermSeconds",
  "MIN_TERM_SECONDS",
  "MIN_LOAN_PRINCIPAL",
  "GRACE_PERIOD",
  "LoanOpened",
  "LoanRepaid",
  "LoanDefaulted",
  "DefaultReportOpened",
]);

const standingPool = trim(artifact("StandingPool.sol", "StandingPool"), [
  "asset",
  "name",
  "symbol",
  "decimals",
  "totalAssets",
  "totalSupply",
  "balanceOf",
  "availableLiquidity",
  "outstandingPrincipal",
  "utilizationBps",
  "lifetimeInterest",
  "lifetimeLosses",
  "maxUtilizationBps",
  "convertToAssets",
  "convertToShares",
  "previewDeposit",
  "previewRedeem",
  "maxDeposit",
  "maxMint",
  "maxWithdraw",
  "maxRedeem",
  "deposit",
  "withdraw",
  "redeem",
  "checkTransfer",
  "checkTransferDetailed",
  "checkParty",
  "isProtocolRegistered",
  "credentialOf",
  "apassRegistry",
  "policy",
  "validator",
  "verifiedAsset",
]);

const standingRegistry = trim(artifact("StandingRegistry.sol", "StandingRegistry"), [
  "historyOf",
  "walletsOf",
  "walletDefaults",
  "canonicalIdentity",
  "supersedes",
  "MIN_QUALIFYING_HOLD",
]);

const cleanversePolicy = trim(artifact("ICleanverse.sol", "ICleanversePolicy"), [
  "canTransfer",
  "isTokenRegistered",
  "isFrozen",
  "isPaused",
  "apass",
]);

// Distinct from the token policy: the policy carries the rules of an asset, the
// validator carries the rules of a registered contract. The per-party verdict is not
// in this ABI — Cleanverse publishes no name for it, so it is called by raw selector.
const cleanverseValidator = trim(artifact("ICleanverse.sol", "ICleanverseValidator"), [
  "isRegistered",
  "apass",
  "tokenPolicy",
]);

const cleanverseAsset = trim(artifact("ICleanverse.sol", "ICleanverseAsset"), [
  "policy",
  "decimals",
  "balanceOf",
  "approve",
  "totalSupply",
]);

const erc20 = trim(artifact("IERC20Metadata.sol", "IERC20Metadata"), [
  "name",
  "symbol",
  "decimals",
  "balanceOf",
  "allowance",
  "approve",
  "totalSupply",
]);

const banner = `// GENERATED FILE - do not edit by hand.
// Source: ../contracts/out/*.sol/*.json (Foundry artifacts).
// Regenerate with: npm run abi
`;

const body = [
  banner,
  `export const complianceGateAbi = ${JSON.stringify(complianceGate, null, 2)} as const;`,
  `export const creditManagerAbi = ${JSON.stringify(creditManager, null, 2)} as const;`,
  `export const standingPoolAbi = ${JSON.stringify(standingPool, null, 2)} as const;`,
  `export const standingRegistryAbi = ${JSON.stringify(standingRegistry, null, 2)} as const;`,
  `export const cleanversePolicyAbi = ${JSON.stringify(cleanversePolicy, null, 2)} as const;`,
  `export const cleanverseValidatorAbi = ${JSON.stringify(cleanverseValidator, null, 2)} as const;`,
  `export const cleanverseAssetAbi = ${JSON.stringify(cleanverseAsset, null, 2)} as const;`,
  `export const erc20Abi = ${JSON.stringify(erc20, null, 2)} as const;`,
].join("\n\n");

mkdirSync(dirname(TARGET), { recursive: true });
writeFileSync(TARGET, body + "\n", "utf8");
console.log(`wrote ${TARGET}`);
console.log(
  [
    ["ComplianceGate", complianceGate],
    ["CreditManager", creditManager],
    ["StandingPool", standingPool],
    ["StandingRegistry", standingRegistry],
    ["ICleanversePolicy", cleanversePolicy],
    ["ICleanverseValidator", cleanverseValidator],
    ["ICleanverseAsset", cleanverseAsset],
    ["IERC20Metadata", erc20],
  ]
    .map(([n, a]) => `  ${n}: ${a.length} entries`)
    .join("\n"),
);
