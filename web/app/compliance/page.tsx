"use client";

import { useEffect, useMemo, useState } from "react";
import { getAddress, type Address } from "viem";
import { useSubject } from "@/lib/subject";
import {
  ASSET_SYMBOL,
  CONTRACTS,
  REFERENCE_WALLETS,
  REFUSAL,
  REFUSAL_PROSE,
} from "@/lib/contracts";
import { isAddressish, parseUnits6, truncateMid } from "@/lib/format";
import { Panel, Tag } from "@/components/primitives";
import { ScreenHead } from "@/components/ScreenHead";
import { GateStack } from "@/components/compliance/GateStack";
import { PoolCredential } from "@/components/compliance/PoolCredential";
import { useGateSequence } from "@/components/compliance/useGateSequence";

export default function ComplianceScreen() {
  const { subject } = useSubject();

  const [fromRaw, setFromRaw] = useState<string>(CONTRACTS.standingPool);
  const [toRaw, setToRaw] = useState<string>("");
  const [amountInput, setAmountInput] = useState("1000");

  // The subject bar drives the recipient by default; typing here overrides it.
  const [toTouched, setToTouched] = useState(false);
  useEffect(() => {
    if (!toTouched && subject) setToRaw(subject);
  }, [subject, toTouched]);

  const from = useMemo(() => safeAddress(fromRaw), [fromRaw]);
  const to = useMemo(() => safeAddress(toRaw), [toRaw]);
  const amount = parseUnits6(amountInput) ?? 0n;

  const { gates, verdict, evaluatedAt, rerun } = useGateSequence(from, to, amount);

  const firstDenyIndex = gates.findIndex((g) => g.status === "deny");

  const presets: { label: string; note: string; from: Address; to: Address | undefined }[] = [
    {
      label: "Disbursement",
      note: "pool → borrower",
      from: CONTRACTS.standingPool,
      to: subject ?? REFERENCE_WALLETS[0].address,
    },
    {
      label: "Repayment",
      note: "borrower → pool",
      from: subject ?? REFERENCE_WALLETS[0].address,
      to: CONTRACTS.standingPool,
    },
    {
      label: "Peer transfer",
      note: "wallet → wallet",
      from: REFERENCE_WALLETS[0].address,
      to: REFERENCE_WALLETS[1].address,
    },
    {
      label: "To an unverified wallet",
      note: "wallet → no A-Pass",
      from: REFERENCE_WALLETS[0].address,
      to: REFERENCE_WALLETS[2].address,
    },
  ];

  const activeCode =
    verdict.kind === "refused" ? verdict.code : verdict.kind === "allowed" ? 0 : -1;

  return (
    <div className="space-y-4">
      <ScreenHead
        title="Compliance"
        blurb="The check that runs inside the transaction that moves the money, against live state, every time. Type any two addresses and watch each condition resolve — the refusals are the point, not the exception."
      />

      <PoolCredential />

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,23rem)]">
        <div className="min-w-0 space-y-4">
          {/* ---- the transfer under test --------------------------------- */}
          <Panel
            label="Transfer under evaluation"
            sub="nothing is signed — this is a view call"
            right={
              <div className="flex items-center gap-2">
                {evaluatedAt ? (
                  <span className="lbl-micro">block {evaluatedAt.toString()}</span>
                ) : null}
                <button className="btn !px-2.5 !py-1" onClick={() => void rerun()}>
                  Re-evaluate
                </button>
              </div>
            }
          >
            <div className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_11rem]">
              <Party
                id="from"
                label="From — sending party"
                value={fromRaw}
                onChange={(v) => setFromRaw(v)}
              />
              <Party
                id="to"
                label="To — receiving party"
                value={toRaw}
                onChange={(v) => {
                  setToTouched(true);
                  setToRaw(v);
                }}
              />
              <div>
                <label className="lbl mb-2 block" htmlFor="amt">
                  Amount
                </label>
                <div className="relative">
                  <input
                    id="amt"
                    className="field pr-14"
                    inputMode="decimal"
                    value={amountInput}
                    onChange={(e) => setAmountInput(e.target.value)}
                  />
                  <span className="lbl-micro pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2">
                    {ASSET_SYMBOL}
                  </span>
                </div>
              </div>
            </div>

            <div className="mt-3 flex flex-wrap items-center gap-1.5 border-t border-[var(--color-line)] pt-3">
              <span className="lbl mr-1">Legs</span>
              {presets.map((p) => {
                const active =
                  from?.toLowerCase() === p.from.toLowerCase() &&
                  p.to !== undefined &&
                  to?.toLowerCase() === p.to.toLowerCase();
                return (
                  <button
                    key={p.label}
                    className={`btn !px-2.5 !py-1 ${active ? "btn-key" : ""}`}
                    title={p.note}
                    onClick={() => {
                      setFromRaw(p.from);
                      setToTouched(true);
                      setToRaw(p.to ?? "");
                    }}
                  >
                    {p.label}
                  </button>
                );
              })}
            </div>
          </Panel>

          {/* ---- the sequence -------------------------------------------- */}
          <div>
            <div className="mb-2.5 flex items-baseline justify-between gap-3">
              <span className="lbl">Conditions · evaluated in contract order</span>
              <span className="lbl-micro">
                {from && to
                  ? `${truncateMid(from, 6, 4)} → ${truncateMid(to, 6, 4)}`
                  : "awaiting parties"}
              </span>
            </div>
            <GateStack gates={gates} verdict={verdict} firstDenyIndex={firstDenyIndex} />
          </div>
        </div>

        {/* ---- the codebook ---------------------------------------------- */}
        <div className="min-w-0">
          <Panel
            label="Refusal codebook"
            sub="the enum, in full"
            bodyClass="p-0"
            right={<Tag tone="idle">6 VALUES</Tag>}
          >
            <ul className="divide-y divide-[var(--color-line)]">
              {REFUSAL.map((name, code) => {
                const active = code === activeCode;
                return (
                  <li
                    key={name}
                    className="p-3.5 transition-colors"
                    style={{
                      background: active
                        ? code === 0
                          ? "var(--color-teal-wash)"
                          : "var(--color-refuse-wash)"
                        : undefined,
                    }}
                  >
                    <div className="flex items-baseline gap-2.5">
                      <span
                        className={`num text-[0.8125rem] ${
                          active
                            ? code === 0
                              ? "text-[var(--color-teal)]"
                              : "text-[var(--color-refuse)]"
                            : "text-[var(--color-bone-ghost)]"
                        }`}
                      >
                        {code}
                      </span>
                      <span
                        className={`num text-[0.8125rem] ${
                          active
                            ? code === 0
                              ? "text-[var(--color-teal)]"
                              : "text-[var(--color-refuse)]"
                            : "text-[var(--color-bone-dim)]"
                        }`}
                      >
                        {name}
                      </span>
                      {active ? (
                        <span className="ml-auto">
                          <Tag tone={code === 0 ? "pass" : "deny"}>CURRENT</Tag>
                        </span>
                      ) : null}
                    </div>
                    <p className="mt-1.5 text-[0.75rem] leading-relaxed text-[var(--color-bone-faint)]">
                      {REFUSAL_PROSE[name]}
                    </p>
                  </li>
                );
              })}
            </ul>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Party({
  id,
  label,
  value,
  onChange,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const bad = value.trim().length > 0 && !isAddressish(value);
  return (
    <div>
      <label className="lbl mb-2 block" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className={`field ${bad ? "!border-[var(--color-refuse)]" : ""}`}
        spellCheck={false}
        autoComplete="off"
        placeholder="0x…"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

function safeAddress(v: string): Address | undefined {
  if (!isAddressish(v)) return undefined;
  try {
    return getAddress(v.trim());
  } catch {
    return undefined;
  }
}
