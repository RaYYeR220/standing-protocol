"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Address } from "viem";
import { publicClient } from "@/lib/client";
import { cleanversePolicyAbi, creditManagerAbi } from "@/lib/abi";
import { CONTRACTS, refusalName } from "@/lib/contracts";
import { revertSelector, shortError, truncateMid } from "@/lib/format";

/** A revert from the policy engine, said plainly. Fail-closed is the point. */
function revertProse(e: unknown, subject: string) {
  const sel = revertSelector(e);
  const what = sel
    ? `${subject} reverted with ${sel}, a custom error Cleanverse does not publish an ABI for`
    : `${subject} reverted — ${shortError(e)}`;
  return `${what}. The gate treats a revert as a refusal: if compliance cannot be established, value does not move.`;
}

export type GateStatus = "idle" | "running" | "pass" | "deny" | "skip";

export type Gate = {
  id: "sender" | "recipient" | "asset" | "protocol";
  index: string;
  title: string;
  claim: string;
  /** The exact call this condition is decided by. */
  call: string;
  status: GateStatus;
  /** Raw return value, rendered verbatim. */
  ret?: string;
  /** Refusal enum ordinal, when the condition produced one. */
  code?: number;
  /** One line of context — a revert, a party, a registration state. */
  detail?: string;
  party?: Address;
};

export type Verdict =
  | { kind: "idle" }
  | { kind: "running" }
  | { kind: "allowed" }
  | { kind: "refused"; code: number; party: Address }
  | { kind: "fault"; message: string };

const BASE: Omit<Gate, "status">[] = [
  {
    id: "sender",
    index: "01",
    title: "Sender credential",
    claim: "The sending party holds an A-Pass that is present, active and unexpired.",
    call: "CreditManager.checkParty(from)",
  },
  {
    id: "recipient",
    index: "02",
    title: "Recipient credential",
    claim: "So does the receiving party. Both ends are checked, every time.",
    call: "CreditManager.checkParty(to)",
  },
  {
    id: "asset",
    index: "03",
    title: "Asset policy",
    claim: "Cleanverse's policy engine permits the movement under aUSDC's own rule set.",
    call: "CleanversePolicy.canTransfer(aUSDC, from, to, amount)",
  },
  {
    id: "protocol",
    index: "04",
    title: "Protocol policy",
    claim:
      "If Standing Protocol is registered as a policy subject, its own rule set permits it too.",
    call: "CleanversePolicy.canTransfer(CreditManager, from, to, amount)",
  },
];

/** Long enough that a resolution registers as an event rather than a repaint. */
const DWELL = 420;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Walks the gate one condition at a time, in the order the contract evaluates them,
 * and reports each as it resolves. The composite verdict comes from the contract's
 * own checkTransferDetailed — the per-condition reads are the working, not the answer.
 */
export function useGateSequence(
  from: Address | undefined,
  to: Address | undefined,
  amount: bigint,
) {
  const [gates, setGates] = useState<Gate[]>(() =>
    BASE.map((g) => ({ ...g, status: "idle" as GateStatus })),
  );
  const [verdict, setVerdict] = useState<Verdict>({ kind: "idle" });
  const [evaluatedAt, setEvaluatedAt] = useState<bigint | null>(null);
  const runId = useRef(0);

  const patch = useCallback((id: Gate["id"], next: Partial<Gate>, mine: number) => {
    if (mine !== runId.current) return;
    setGates((prev) => prev.map((g) => (g.id === id ? { ...g, ...next } : g)));
  }, []);

  const run = useCallback(async () => {
    if (!from || !to) {
      runId.current += 1;
      setGates(BASE.map((g) => ({ ...g, status: "idle" as GateStatus })));
      setVerdict({ kind: "idle" });
      return;
    }

    const mine = ++runId.current;
    setGates(BASE.map((g) => ({ ...g, status: "idle" as GateStatus })));
    setVerdict({ kind: "running" });
    setEvaluatedAt(null);

    try {
      const block = await publicClient.getBlockNumber();
      if (mine !== runId.current) return;
      setEvaluatedAt(block);

      // ---- 01 / 02 — the credential of each end -------------------------
      for (const [id, party, label] of [
        ["sender", from, "from"],
        ["recipient", to, "to"],
      ] as const) {
        patch(id, { status: "running" }, mine);
        const started = Date.now();
        const [ok, code] = (await publicClient.readContract({
          address: CONTRACTS.creditManager,
          abi: creditManagerAbi,
          functionName: "checkParty",
          args: [party],
        })) as readonly [boolean, number];
        await sleep(Math.max(0, DWELL - (Date.now() - started)));
        patch(
          id,
          {
            status: ok ? "pass" : "deny",
            ret: `(${ok}, ${code})`,
            code,
            party,
            detail: ok
              ? `${label} = ${truncateMid(party, 8, 6)} — credential live`
              : `${label} = ${truncateMid(party, 8, 6)} — ${refusalName(code)}`,
          },
          mine,
        );
        if (mine !== runId.current) return;
      }

      // ---- 03 — the asset's own rules -----------------------------------
      patch("asset", { status: "running" }, mine);
      {
        const started = Date.now();
        let status: GateStatus = "deny";
        let ret = "false";
        let detail =
          "the policy engine refused. A refusal here is final — the asset carries its rules with it.";
        try {
          const ok = (await publicClient.readContract({
            address: CONTRACTS.policy,
            abi: cleanversePolicyAbi,
            functionName: "canTransfer",
            args: [CONTRACTS.verifiedAsset, from, to, amount],
          })) as boolean;
          status = ok ? "pass" : "deny";
          ret = String(ok);
          if (ok) detail = "aUSDC's rule set permits this movement between these parties.";
        } catch (e) {
          status = "deny";
          ret = "revert";
          detail = revertProse(e, "the policy engine");
        }
        await sleep(Math.max(0, DWELL - (Date.now() - started)));
        patch(
          "asset",
          { status, ret, detail, code: status === "deny" ? 4 : 0 },
          mine,
        );
        if (mine !== runId.current) return;
      }

      // ---- 04 — the protocol's own rules, if it has any -------------------
      patch("protocol", { status: "running" }, mine);
      {
        const started = Date.now();
        let registered = false;
        try {
          registered = (await publicClient.readContract({
            address: CONTRACTS.policy,
            abi: cleanversePolicyAbi,
            functionName: "isTokenRegistered",
            args: [CONTRACTS.creditManager],
          })) as boolean;
        } catch {
          registered = false;
        }

        if (!registered) {
          await sleep(Math.max(0, DWELL - (Date.now() - started)));
          patch(
            "protocol",
            {
              status: "skip",
              ret: "isTokenRegistered = false",
              detail:
                "Standing Protocol is not currently registered as a policy subject, so it carries no rule set of its own and this condition does not apply. Registering it is an off-chain administrative act; the contracts enforce the asset's rules either way.",
            },
            mine,
          );
        } else {
          let status: GateStatus = "deny";
          let ret = "false";
          let detail = "the protocol's own rule set refused this movement.";
          try {
            const ok = (await publicClient.readContract({
              address: CONTRACTS.policy,
              abi: cleanversePolicyAbi,
              functionName: "canTransfer",
              args: [CONTRACTS.creditManager, from, to, amount],
            })) as boolean;
            status = ok ? "pass" : "deny";
            ret = String(ok);
            if (ok) detail = "the protocol's own rule set permits this movement.";
          } catch (e) {
            status = "deny";
            ret = "revert";
            detail = revertProse(e, "the policy engine");
          }
          await sleep(Math.max(0, DWELL - (Date.now() - started)));
          patch("protocol", { status, ret, detail, code: status === "deny" ? 5 : 0 }, mine);
        }
        if (mine !== runId.current) return;
      }

      // ---- the contract's own composite answer ---------------------------
      const [allowed, code, party] = (await publicClient.readContract({
        address: CONTRACTS.creditManager,
        abi: creditManagerAbi,
        functionName: "checkTransferDetailed",
        args: [from, to, amount],
      })) as readonly [boolean, number, Address];
      if (mine !== runId.current) return;
      setVerdict(allowed ? { kind: "allowed" } : { kind: "refused", code, party });
    } catch (e) {
      if (mine !== runId.current) return;
      setVerdict({ kind: "fault", message: shortError(e) });
    }
  }, [from, to, amount, patch]);

  // Re-evaluate on any change to the transfer being tested.
  useEffect(() => {
    const t = setTimeout(() => void run(), 450);
    return () => clearTimeout(t);
  }, [run]);

  return { gates, verdict, evaluatedAt, rerun: run };
}
