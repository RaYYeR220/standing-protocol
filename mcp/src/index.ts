#!/usr/bin/env node
/**
 * Standing — MCP server.
 *
 * An under-collateralized credit book is only trustworthy if someone can interrogate it. This
 * exposes the protocol's underwriting as tools an operator's assistant can call: what would this
 * borrower be offered, why, who is refused and on which condition, and what is on the book right
 * now. Every answer is read live from Monad and rendered from the same numbers the contract
 * enforced — the server holds no keys, signs nothing and cannot move a cent.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createPublicClient, http, defineChain, getAddress, formatUnits } from "viem";
import { z } from "zod";
import { CREDIT_MANAGER_ABI, POOL_ABI, REGISTRY_ABI } from "./abi.js";
import { explainCredential, explainQuote, refusal, amount, pct } from "./rationale.js";
import { LOAN_STATUS, type Credential, type Hex, type History, type Loan, type Quote } from "./types.js";

const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [process.env.MONAD_RPC_URL ?? "https://testnet-rpc.monad.xyz"] } },
  blockExplorers: { default: { name: "Monad Explorer", url: "https://testnet.monadexplorer.com" } },
});

const CREDIT_MANAGER = (process.env.CREDIT_MANAGER ??
  "0x77502D2AfBE8c2Bb3e9cD7ae9f0468e6D25997cb") as Hex;
const POOL = (process.env.STANDING_POOL ?? "0x382B067B3917f07880795396b6684e30B9d30907") as Hex;
const REGISTRY = (process.env.STANDING_REGISTRY ??
  "0x05d68e4B5d79994096AeB62A04333C7491D63eD0") as Hex;

const client = createPublicClient({ chain: monadTestnet, transport: http() });
const DAY = 86_400n;

const address = z.string().regex(/^0x[a-fA-F0-9]{40}$/, "expected a 20-byte hex address");

function text(lines: string[]) {
  return { content: [{ type: "text" as const, text: lines.join("\n") }] };
}

function explorer(kind: "address" | "tx", v: string) {
  return `https://testnet.monadexplorer.com/${kind}/${v}`;
}

const server = new McpServer({ name: "standing", version: "1.0.0" });

server.tool(
  "standing_quote",
  "Underwrite a borrower: the credit line, collateral and rate the protocol would offer for a " +
    "given principal and term, with the full score breakdown and the reason for any refusal.",
  {
    borrower: address.describe("wallet to underwrite"),
    amount: z.number().positive().describe("principal requested, in whole aUSDC"),
    termDays: z.number().int().min(1).max(365).default(90),
  },
  async ({ borrower, amount: amt, termDays }) => {
    const who = getAddress(borrower) as Hex;
    const principal = BigInt(Math.round(amt * 1e6));
    const [q, c] = (await Promise.all([
      client.readContract({
        address: CREDIT_MANAGER,
        abi: CREDIT_MANAGER_ABI,
        functionName: "quote",
        args: [who, principal, BigInt(termDays) * DAY],
      }),
      client.readContract({
        address: CREDIT_MANAGER,
        abi: CREDIT_MANAGER_ABI,
        functionName: "credentialOf",
        args: [who],
      }),
    ])) as [Quote, Credential];

    return text([
      `Borrower ${who} — ${explorer("address", who)}`,
      `Request: ${amt} aUSDC for ${termDays} days`,
      "",
      ...explainQuote(q, c),
      "",
      `Interest over the term: ${amount(q.interestForTerm)} aUSDC`,
    ]);
  }
);

server.tool(
  "standing_check_compliance",
  "Evaluate Cleanverse's compliance gate for a transfer between two parties, exactly as the " +
    "contract would inside a transaction. Names the party that fails and the condition it fails on.",
  {
    from: address,
    to: address,
    amount: z.number().nonnegative().default(0).describe("transfer amount in whole aUSDC"),
  },
  async ({ from, to, amount: amt }) => {
    const value = BigInt(Math.round(amt * 1e6));
    const [allowed, reason, party] = (await client.readContract({
      address: CREDIT_MANAGER,
      abi: CREDIT_MANAGER_ABI,
      functionName: "checkTransferDetailed",
      args: [getAddress(from) as Hex, getAddress(to) as Hex, value],
    })) as [boolean, number, Hex];

    if (allowed) {
      return text([
        `ALLOWED — ${from} may send ${amt} aUSDC to ${to}.`,
        "",
        "All four conditions hold: both parties carry a live A-Pass, and Cleanverse's policy",
        "engine permits the movement under the asset's rules and this protocol's own rule set.",
      ]);
    }
    return text([
      `REFUSED — reason code ${reason}.`,
      `Offending party: ${party} (${explorer("address", party)})`,
      "",
      `In plain terms: ${refusal(reason)}.`,
      "",
      "This verdict is computed on-chain, and the same call inside a transaction would revert",
      "before any value moved.",
    ]);
  }
);

server.tool(
  "standing_identity",
  "Everything the protocol knows about an identity: its live Cleanverse credential, the credit " +
    "history keyed to it, and every wallet seen acting under it.",
  { wallet: address },
  async ({ wallet }) => {
    const who = getAddress(wallet) as Hex;
    const c = (await client.readContract({
      address: CREDIT_MANAGER,
      abi: CREDIT_MANAGER_ABI,
      functionName: "credentialOf",
      args: [who],
    })) as Credential;

    if (!c.exists) return text([`${who} holds no Cleanverse A-Pass.`]);

    const identity = (await client.readContract({
      address: REGISTRY,
      abi: REGISTRY_ABI,
      functionName: "canonicalIdentity",
      args: [c.kycHash],
    })) as Hex;

    const [h, wallets] = (await Promise.all([
      client.readContract({
        address: REGISTRY,
        abi: REGISTRY_ABI,
        functionName: "historyOf",
        args: [identity],
      }),
      client.readContract({
        address: REGISTRY,
        abi: REGISTRY_ABI,
        functionName: "walletsOf",
        args: [identity],
      }),
    ])) as [History, readonly Hex[]];

    const drawn = (await client.readContract({
      address: CREDIT_MANAGER,
      abi: CREDIT_MANAGER_ABI,
      functionName: "drawnByIdentity",
      args: [identity],
    })) as bigint;

    return text([
      `${who} — ${explorer("address", who)}`,
      "",
      ...explainCredential(c, h, wallets as string[]),
      "",
      `Canonical identity: ${identity}`,
      `Currently drawn against this identity: ${amount(drawn)} aUSDC`,
    ]);
  }
);

server.tool(
  "standing_loan_book",
  "The whole loan book: every loan, its status, terms, and whether it is past its grace period " +
    "and can be written off by anyone.",
  { onlyActive: z.boolean().default(false) },
  async ({ onlyActive }) => {
    const count = (await client.readContract({
      address: CREDIT_MANAGER,
      abi: CREDIT_MANAGER_ABI,
      functionName: "loanCount",
    })) as bigint;

    if (count === 0n) return text(["The book is empty — no loans have been originated."]);

    const rows: string[] = [];
    for (let id = 1n; id <= count; id++) {
      const l = (await client.readContract({
        address: CREDIT_MANAGER,
        abi: CREDIT_MANAGER_ABI,
        functionName: "loan",
        args: [id],
      })) as Loan;
      if (onlyActive && l.status !== 1) continue;
      const defaultable =
        l.status === 1
          ? ((await client.readContract({
              address: CREDIT_MANAGER,
              abi: CREDIT_MANAGER_ABI,
              functionName: "isDefaultable",
              args: [id],
            })) as boolean)
          : false;
      rows.push(
        `#${id} ${LOAN_STATUS[l.status]} — ${amount(l.principal)} aUSDC principal, ` +
          `${amount(l.collateral)} collateral (${(Number(l.collateral) / Number(l.principal) * 100).toFixed(0)}%), ` +
          `${pct(l.aprBps)} APR, due ${new Date(Number(l.dueAt) * 1000).toISOString().slice(0, 10)}` +
          (defaultable ? "  ** past grace: anyone may write this off **" : "") +
          `\n     borrower ${l.borrower}`
      );
    }
    return text([`${count} loan(s) originated.`, "", ...rows]);
  }
);

server.tool(
  "standing_pool",
  "The lending pool's position: assets, liquidity, utilization, interest earned and losses taken.",
  {},
  async () => {
    const [total, liquid, outstanding, util, interest, losses, perShare] = (await Promise.all(
      (
        [
          "totalAssets",
          "availableLiquidity",
          "outstandingPrincipal",
          "utilizationBps",
          "lifetimeInterest",
          "lifetimeLosses",
        ] as const
      )
        .map((fn) => client.readContract({ address: POOL, abi: POOL_ABI, functionName: fn }))
        .concat([
          client.readContract({
            address: POOL,
            abi: POOL_ABI,
            functionName: "convertToAssets",
            args: [10n ** 12n],
          }),
        ])
    )) as bigint[];

    return text([
      `Pool ${POOL} — ${explorer("address", POOL)}`,
      "",
      `Total assets        ${amount(total)} aUSDC`,
      `Available liquidity ${amount(liquid)} aUSDC`,
      `Out on loan         ${amount(outstanding)} aUSDC`,
      `Utilization         ${pct(util)}`,
      `Interest earned     ${amount(interest)} aUSDC`,
      `Losses absorbed     ${amount(losses)} aUSDC`,
      `Assets per share    ${formatUnits(perShare, 6)}`,
      "",
      losses > 0n
        ? "Losses are carried by the share price. There is no reserve absorbing them."
        : "No defaults have been written off against this pool.",
    ]);
  }
);

await server.connect(new StdioServerTransport());
