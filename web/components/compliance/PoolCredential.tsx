"use client";

import { Addr, Note, Panel, Tag } from "../primitives";
import { APASS_STATUS, CONTRACTS, refusalName } from "@/lib/contracts";
import { useCheckParty, useCredential } from "@/lib/reads";

/**
 * The pool is a party to every disbursement, so the pool needs its own A-Pass.
 * Whatever that read says is what goes on the screen.
 */
export function PoolCredential() {
  const cred = useCredential(CONTRACTS.standingPool);
  const check = useCheckParty(CONTRACTS.standingPool);

  const ok = check.data?.[0];
  const code = check.data?.[1];

  return (
    <Panel
      label="The protocol's own standing"
      sub="StandingPool as a party, not an intermediary"
      right={
        check.error ? (
          <Tag tone="deny">RPC FAULT</Tag>
        ) : ok === undefined ? (
          <Tag tone="idle">READING</Tag>
        ) : ok ? (
          <Tag tone="pass">VERIFIED PARTICIPANT</Tag>
        ) : (
          <Tag tone="deny">UNCREDENTIALED</Tag>
        )
      }
    >
      <div className="flex flex-wrap items-center gap-x-8 gap-y-3">
        <Field label="Pool">
          <Addr address={CONTRACTS.standingPool} head={10} tail={8} />
        </Field>
        <Field label="A-Pass">
          {cred.error ? (
            <Tag tone="deny">RPC FAULT</Tag>
          ) : cred.data === undefined ? (
            <span className="num text-[0.75rem] text-[var(--color-bone-ghost)] sp-pulse">······</span>
          ) : cred.data.exists ? (
            <span className="num text-[0.75rem]">
              {APASS_STATUS[cred.data.status] ?? cred.data.status} · tier {cred.data.tier}
            </span>
          ) : (
            <span className="num text-[0.75rem] text-[var(--color-refuse)]">exists = false</span>
          )}
        </Field>
        <Field label="checkParty">
          {check.data ? (
            <span
              className={`num text-[0.75rem] ${ok ? "text-[var(--color-teal)]" : "text-[var(--color-refuse)]"}`}
            >
              ({String(ok)}, {code}) {code ? `· ${refusalName(code)}` : ""}
            </span>
          ) : (
            <span className="num text-[0.75rem] text-[var(--color-bone-ghost)]">······</span>
          )}
        </Field>
      </div>

      <div className="mt-3 border-t border-[var(--color-line)] pt-3">
        {ok === false ? (
          <p className="max-w-[86ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
            The pool does not hold an A-Pass right now, so{" "}
            <span className="num text-[var(--color-refuse)]">every disbursement is refused</span> —
            the sender fails condition 01 before the borrower is even looked at. This is not a
            degraded mode or a bug to route around: a protocol that moves a verified asset has to be
            a verified participant in the network itself, and the gate has no exception for the
            contract that owns it. The refusal below is the system working.
          </p>
        ) : (
          <Note>
            The pool holds a live credential, so it can act as a party to a transfer. The gate has no
            exception for the protocol&apos;s own contracts — it is checked exactly like a wallet.
          </Note>
        )}
      </div>
    </Panel>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="leading-none">
      <div className="lbl-micro mb-1.5">{label}</div>
      {children}
    </div>
  );
}
