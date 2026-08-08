"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { encodeAbiParameters, parseAbiParameters, type Address, type Hex } from "viem";
import { publicClientFor } from "@/lib/client";
import { cleanversePolicyAbi, complianceGateAbi, creditManagerAbi } from "@/lib/abi";
import { refusalName } from "@/lib/contracts";
import { useNetwork } from "@/lib/network";
import { revertSelector, shortError, truncateMid } from "@/lib/format";

/**
 * The validator's per-party verdict. Cleanverse publishes no name for it, so it is
 * bound by raw selector exactly as ComplianceGate binds it, and the returned word is
 * compared to 1 rather than decoded as a bool — a malformed answer is a refusal, not
 * a thrown decode.
 */
const VALIDATOR_VERIFY = "0xaf375463";

async function validatorVerdict(
  client: { call: (a: { to: Address; data: Hex }) => Promise<{ data?: Hex }> },
  validator: Address,
  subject: Address,
  party: Address,
): Promise<boolean> {
  const args = encodeAbiParameters(parseAbiParameters("address, address"), [subject, party]);
  const res = await client.call({ to: validator, data: `${VALIDATOR_VERIFY}${args.slice(2)}` as Hex });
  if (!res.data || res.data.length < 66) return false;
  return BigInt(res.data) === 1n;
}

/** A revert from a Cleanverse contract, said plainly. Fail-closed is the point. */
function revertProse(e: unknown, subject: string) {
  const sel = revertSelector(e);
  const what = sel
    ? `${subject} reverted with ${sel}, a custom error Cleanverse does not publish an ABI for`
    : `${subject} reverted — ${shortError(e)}`;
  return `${what}. The gate treats a revert as a refusal: if compliance cannot be established, value does not move.`;
}

export type GateStatus = "idle" | "running" | "pass" | "deny" | "skip";

export type GateId = "sender" | "recipient" | "asset" | "protocolFrom" | "protocolTo";

export type Gate = {
  id: GateId;
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
    id: "protocolFrom",
    index: "04",
    title: "Protocol policy — sender",
    claim:
      "Standing Protocol carries its own rule set at Cleanverse's validator, and that rule set admits the sending party.",
    call: "Validator.0xaf375463(CreditManager, from)",
  },
  {
    id: "protocolTo",
    index: "05",
    title: "Protocol policy — recipient",
    claim:
      "The same rule set is asked about the receiving party separately. Each refusal names the party it was asked about.",
    call: "Validator.0xaf375463(CreditManager, to)",
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
  const { key: networkKey, contracts } = useNetwork();
  const [gates, setGates] = useState<Gate[]>(() =>
    BASE.map((g) => ({ ...g, status: "idle" as GateStatus })),
  );
  const [verdict, setVerdict] = useState<Verdict>({ kind: "idle" });
  const [evaluatedAt, setEvaluatedAt] = useState<bigint | null>(null);
  const runId = useRef(0);

  const patch = useCallback((id: GateId, next: Partial<Gate>, mine: number) => {
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
    const publicClient = publicClientFor(networkKey);
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
          address: contracts.creditManager,
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
            address: contracts.policy,
            abi: cleanversePolicyAbi,
            functionName: "canTransfer",
            args: [contracts.verifiedAsset, from, to, amount],
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

      // ---- 04 / 05 — the protocol's own rule set, asked party by party ----
      let isRegistered = false;
      try {
        isRegistered = (await publicClient.readContract({
          address: contracts.creditManager,
          abi: complianceGateAbi,
          functionName: "isProtocolRegistered",
        })) as boolean;
      } catch {
        isRegistered = false;
      }
      if (mine !== runId.current) return;

      for (const [id, party, label] of [
        ["protocolFrom", from, "from"],
        ["protocolTo", to, "to"],
      ] as const) {
        patch(id, { status: "running" }, mine);
        const started = Date.now();

        if (!isRegistered) {
          await sleep(Math.max(0, DWELL - (Date.now() - started)));
          patch(
            id,
            {
              status: "skip",
              ret: "isProtocolRegistered = false",
              party,
              detail:
                "Standing Protocol is not registered with Cleanverse's validator at this block, so it carries no rule set of its own and this condition does not apply. Registration is an off-chain administrative act; the contracts enforce the asset's rules either way.",
            },
            mine,
          );
          if (mine !== runId.current) return;
          continue;
        }

        let status: GateStatus = "deny";
        let ret = "0";
        let detail = `${label} = ${truncateMid(party, 8, 6)} — the protocol's own rule set refused this party.`;
        try {
          const ok = await validatorVerdict(
            publicClient,
            contracts.validator,
            contracts.creditManager,
            party,
          );
          status = ok ? "pass" : "deny";
          ret = ok ? "1" : "0";
          if (ok) {
            detail = `${label} = ${truncateMid(party, 8, 6)} — admitted by the protocol's registered rule set.`;
          }
        } catch (e) {
          status = "deny";
          ret = "revert";
          detail = revertProse(e, "the validator");
        }
        await sleep(Math.max(0, DWELL - (Date.now() - started)));
        patch(id, { status, ret, detail, party, code: status === "deny" ? 5 : 0 }, mine);
        if (mine !== runId.current) return;
      }

      // ---- the contract's own composite answer ---------------------------
      const [allowed, code, party] = (await publicClient.readContract({
        address: contracts.creditManager,
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
  }, [from, to, amount, patch, networkKey, contracts]);

  // Re-evaluate on any change to the transfer being tested.
  useEffect(() => {
    const t = setTimeout(() => void run(), 450);
    return () => clearTimeout(t);
  }, [run]);

  return { gates, verdict, evaluatedAt, rerun: run };
}
