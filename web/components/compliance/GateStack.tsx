"use client";

import type { Gate, Verdict } from "./useGateSequence";
import { REFUSAL_PROSE, refusalName } from "@/lib/contracts";
import { Addr } from "../primitives";

const STATUS_LABEL: Record<Gate["status"], string> = {
  idle: "QUEUED",
  running: "EVALUATING",
  pass: "PASS",
  deny: "DENY",
  skip: "N/A",
};

function edgeColor(s: Gate["status"]) {
  switch (s) {
    case "pass":
      return "var(--color-teal)";
    case "deny":
      return "var(--color-refuse)";
    case "running":
      return "var(--color-bone-dim)";
    default:
      return "var(--color-line-lift)";
  }
}

/** The four conditions, in the order the contract evaluates them. */
export function GateStack({
  gates,
  verdict,
  firstDenyIndex,
}: {
  gates: Gate[];
  verdict: Verdict;
  firstDenyIndex: number;
}) {
  return (
    <ol className="space-y-2">
      {gates.map((g, i) => (
        <li key={g.id}>
          <GateRow gate={g} shortCircuited={firstDenyIndex >= 0 && i > firstDenyIndex} />
        </li>
      ))}
      <li className="pt-1">
        <VerdictSlab verdict={verdict} />
      </li>
    </ol>
  );
}

function GateRow({ gate, shortCircuited }: { gate: Gate; shortCircuited: boolean }) {
  const running = gate.status === "running";
  return (
    <div
      className={`relative overflow-hidden border bg-[var(--color-panel)] ${running ? "sp-scan" : ""}`}
      style={{
        borderColor:
          gate.status === "pass"
            ? "var(--color-teal-deep)"
            : gate.status === "deny"
              ? "var(--color-refuse-deep)"
              : "var(--color-line)",
        opacity: shortCircuited ? 0.55 : 1,
        transition: "opacity 240ms linear, border-color 240ms linear",
      }}
    >
      <span
        aria-hidden
        className="absolute inset-y-0 left-0 w-[3px]"
        style={{ background: edgeColor(gate.status), transition: "background-color 240ms linear" }}
      />
      <div className="flex flex-wrap items-start gap-x-4 gap-y-2 py-3 pl-5 pr-3.5">
        <span
          className={`num shrink-0 text-[0.8125rem] leading-6 ${
            gate.status === "pass"
              ? "text-[var(--color-teal)]"
              : gate.status === "deny"
                ? "text-[var(--color-refuse)]"
                : "text-[var(--color-bone-ghost)]"
          }`}
        >
          {gate.index}
        </span>

        <div className="min-w-[16rem] flex-1">
          <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h3 className="text-[0.875rem] font-medium tracking-[-0.01em]">{gate.title}</h3>
            {gate.ret ? (
              <span className="num text-[0.6875rem] text-[var(--color-bone-faint)]">
                → {gate.ret}
              </span>
            ) : null}
          </div>
          <p className="mt-1 max-w-[70ch] text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
            {gate.claim}
          </p>
          {gate.detail ? (
            <p
              className={`mt-1.5 max-w-[74ch] text-[0.75rem] leading-relaxed ${
                gate.status === "deny"
                  ? "text-[var(--color-refuse)] opacity-90"
                  : "text-[var(--color-bone-faint)]"
              }`}
            >
              {gate.detail}
            </p>
          ) : null}
          <p className="num mt-1.5 text-[0.625rem] text-[var(--color-bone-ghost)]">{gate.call}</p>
          {shortCircuited ? (
            <p className="lbl-micro mt-1.5 !text-[var(--color-bone-faint)]">
              shown for completeness — the contract already returned above
            </p>
          ) : null}
        </div>

        <span
          className={`chip shrink-0 ${
            gate.status === "pass"
              ? "chip-pass"
              : gate.status === "deny"
                ? "chip-deny"
                : "chip-idle"
          }`}
        >
          {gate.status === "running" ? (
            <span className="sp-pulse">{STATUS_LABEL[gate.status]}</span>
          ) : (
            STATUS_LABEL[gate.status]
          )}
        </span>
      </div>
    </div>
  );
}

/** The answer. Rendered as the largest thing on the page, because it is. */
function VerdictSlab({ verdict }: { verdict: Verdict }) {
  if (verdict.kind === "idle") {
    return (
      <div className="border border-dashed border-[var(--color-line-lift)] px-5 py-8 text-center">
        <span className="lbl !tracking-[0.24em]">Awaiting both parties</span>
      </div>
    );
  }

  if (verdict.kind === "running") {
    return (
      <div className="relative overflow-hidden border border-[var(--color-line-lift)] px-5 py-8 text-center sp-scan">
        <span className="num text-[0.875rem] text-[var(--color-bone-dim)] sp-pulse">
          EVALUATING AGAINST LIVE STATE
        </span>
      </div>
    );
  }

  if (verdict.kind === "fault") {
    return (
      <div className="border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-5">
        <div className="lbl !text-[var(--color-refuse)]">RPC FAULT</div>
        <p className="num mt-2 break-words text-[0.75rem] text-[var(--color-refuse)]">
          {verdict.message}
        </p>
        <p className="mt-2 text-[0.75rem] text-[var(--color-bone-faint)]">
          No verdict is being shown. The console does not guess when the chain does not answer.
        </p>
      </div>
    );
  }

  if (verdict.kind === "allowed") {
    return (
      <div className="sp-seat border border-[var(--color-teal-deep)] bg-[var(--color-teal-wash)] p-5">
        <div className="flex flex-wrap items-center gap-4">
          <span className="h-10 w-1 shrink-0 bg-[var(--color-teal)]" aria-hidden />
          <div>
            <div className="lbl-micro mb-1.5">Verdict</div>
            <div className="num text-[2rem] leading-none tracking-[-0.02em] text-[var(--color-teal)]">
              PERMITTED
            </div>
          </div>
        </div>
        <div className="mt-4 grid grid-cols-1 gap-x-8 border-t border-[var(--color-teal-deep)] pt-3 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <span className="lbl">Refusal</span>
          <span className="num text-[0.8125rem] text-[var(--color-bone)]">0 · None</span>
        </div>
        <p className="mt-2.5 max-w-[74ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
          {REFUSAL_PROSE.None} Every condition was re-read inside this call — nothing here is
          carried over from an earlier check.
        </p>
      </div>
    );
  }

  const name = refusalName(verdict.code);
  return (
    <div className="sp-seat border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-5">
      <div className="flex flex-wrap items-center gap-4">
        <span className="h-10 w-1 shrink-0 bg-[var(--color-refuse)]" aria-hidden />
        <div>
          <div className="lbl-micro mb-1.5">Verdict</div>
          <div className="num text-[2rem] leading-none tracking-[-0.02em] text-[var(--color-refuse)]">
            REFUSED
          </div>
        </div>
      </div>

      <dl className="mt-4 grid grid-cols-1 gap-x-8 gap-y-2 border-t border-[var(--color-refuse-deep)] pt-3 sm:grid-cols-[8rem_minmax(0,1fr)]">
        <dt className="lbl">Refusal</dt>
        <dd className="num text-[1.0625rem] leading-none text-[var(--color-refuse)]">
          {verdict.code} · {name}
        </dd>
        <dt className="lbl mt-1">Failing party</dt>
        <dd className="mt-1">
          <Addr address={verdict.party} tone="refuse" head={12} tail={10} />
        </dd>
      </dl>

      <p className="mt-3 max-w-[74ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
        {REFUSAL_PROSE[name]}
      </p>
    </div>
  );
}
