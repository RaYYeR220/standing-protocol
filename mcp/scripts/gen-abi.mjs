// Regenerates src/abi.ts from the Foundry build artifacts in ../contracts/out.
import { readFileSync, writeFileSync } from "node:fs";

const OUT = "../contracts/out";
const WANT = {
  CreditManager: ["CREDIT_MANAGER_ABI", ["quote","credentialOf","checkTransferDetailed","checkTransfer","checkParty","loan","loanCount","isDefaultable","drawnByIdentity","open","repay","markDefault","MIN_LOAN_PRINCIPAL","maxLoanPrincipal","maxCreditLine","maxTermSeconds","GRACE_PERIOD","pool","registry"]],
  StandingPool: ["POOL_ABI", ["totalAssets","availableLiquidity","outstandingPrincipal","utilizationBps","lifetimeInterest","lifetimeLosses","convertToAssets","convertToShares","deposit","withdraw","redeem","balanceOf","asset","maxUtilizationBps","checkTransferDetailed"]],
  StandingRegistry: ["REGISTRY_ABI", ["historyOf","walletsOf","canonicalIdentity","supersedes"]],
};

const parts = [
  "// Generated from the Foundry build artifacts — do not edit by hand.",
  "// Regenerate with: npm run abi",
  "",
];
for (const [name, [constName, fns]] of Object.entries(WANT)) {
  const { abi } = JSON.parse(readFileSync(`${OUT}/${name}.sol/${name}.json`, "utf8"));
  const keep = abi.filter((e) => e.type === "function" && fns.includes(e.name));
  parts.push(`export const ${constName} = ${JSON.stringify(keep, null, 2)} as const;\n`);
}
writeFileSync("src/abi.ts", parts.join("\n"));
console.log("wrote src/abi.ts");
