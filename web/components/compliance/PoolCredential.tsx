"use client";

import type { ReactNode } from "react";
import type { Address } from "viem";
import { Addr, Note, Panel, Tag } from "../primitives";
import { APASS_STATUS, refusalName } from "@/lib/contracts";
import { useNetwork } from "@/lib/network";
import { useCredential, useGateCheckParty, useIsProtocolRegistered } from "@/lib/reads";
import type { Credential, ReadState } from "@/lib/types";

/**
 * The protocol as a party rather than as an intermediary. Both gated contracts hold
 * their own A-Pass and both are registered with Cleanverse's validator, so the
 * protocol is a subject of the compliance system and not merely a consumer of it.
 * Whatever those reads say is what goes on the screen.
 */
export function PoolCredential() {
  const { contracts } = useNetwork();

  const poolCred = useCredential(contracts.standingPool);
  const poolCheck = useGateCheckParty("standingPool", contracts.standingPool);
  const poolReg = useIsProtocolRegistered("standingPool");

  const managerCred = useCredential(contracts.creditManager);
  const managerCheck = useGateCheckParty("creditManager", contracts.creditManager);
  const managerReg = useIsProtocolRegistered("creditManager");

  const reads = [poolCred, poolCheck, poolReg, managerCred, managerCheck, managerReg];
  const faulted = reads.some((r) => r.error);
  const pending = reads.some((r) => r.data === undefined);

  const credentialled = poolCheck.data?.[0] === true && managerCheck.data?.[0] === true;
  const registered = poolReg.data === true && managerReg.data === true;

  const headerTag = faulted ? (
    <Tag tone="deny">RPC FAULT</Tag>
  ) : pending ? (
    <Tag tone="idle">READING</Tag>
  ) : credentialled && registered ? (
    <Tag tone="pass">REGISTERED PARTICIPANT</Tag>
  ) : credentialled ? (
    <Tag tone="idle">CREDENTIALLED · NO RULE SET</Tag>
  ) : (
    <Tag tone="deny">UNCREDENTIALED</Tag>
  );

  return (
    <Panel
      label="The protocol's own standing"
      sub="a subject of the compliance system, not a consumer of it"
      right={headerTag}
      bodyClass="p-0"
    >
      <div className="divide-y divide-[var(--color-line)]">
        <ContractRow
          label="StandingPool"
          note="party to every disbursement and every redemption"
          address={contracts.standingPool}
          cred={poolCred}
          check={poolCheck}
          registered={poolReg}
        />
        <ContractRow
          label="CreditManager"
          note="the subject the validator's per-party rule set is bound to"
          address={contracts.creditManager}
          cred={managerCred}
          check={managerCheck}
          registered={managerReg}
        />
      </div>

      <div className="space-y-2.5 border-t border-[var(--color-line)] px-4 py-3">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <span className="lbl">Cleanverse validator</span>
          <Addr address={contracts.validator} head={10} tail={8} tone="dim" />
        </div>

        {credentialled && registered ? (
          <p className="max-w-[86ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
            Both contracts hold a live A-Pass, so the protocol can be a party to a transfer at all —
            the gate has no exception for the contracts that own it, and{" "}
            <span className="num">checkParty</span> is run against them exactly as it is against a
            wallet. Both are also registered with Cleanverse&apos;s validator, which means the
            protocol carries{" "}
            <span className="num text-[var(--color-teal)]">its own rule set</span> rather than only
            inheriting the asset&apos;s. That rule set is evaluated on-chain against each
            counterparty separately, and an operator can tighten it at Cleanverse without the
            contracts being redeployed.
          </p>
        ) : !credentialled ? (
          <p className="max-w-[86ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
            A contract above does not hold a usable A-Pass at this block, so{" "}
            <span className="num text-[var(--color-refuse)]">every movement through it is refused</span>{" "}
            — the sender fails condition 01 before the counterparty is looked at. That is the gate
            working, not a degraded mode: a protocol that moves a verified asset has to be a verified
            participant in the network itself.
          </p>
        ) : (
          <Note>
            Both contracts are credentialled, but at this block the validator does not report the
            protocol as registered, so conditions 04 and 05 do not apply and only the asset&apos;s own
            rules are enforced. Registration is an off-chain administrative act; the contracts work
            either way.
          </Note>
        )}
      </div>
    </Panel>
  );
}

function ContractRow({
  label,
  note,
  address,
  cred,
  check,
  registered,
}: {
  label: string;
  note: string;
  address: Address;
  cred: ReadState<Credential>;
  check: ReadState<readonly [boolean, number]>;
  registered: ReadState<boolean>;
}) {
  const ok = check.data?.[0];
  const code = check.data?.[1];

  return (
    <div className="px-4 py-3">
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span className="lbl !text-[var(--color-bone-dim)]">{label}</span>
        <Addr address={address} head={10} tail={8} />
      </div>
      <div className="lbl-micro mt-1.5 !tracking-[0.08em] normal-case">{note}</div>

      <div className="mt-3 flex flex-wrap items-start gap-x-8 gap-y-3">
        <Field label="A-Pass">
          {cred.error ? (
            <Tag tone="deny">RPC FAULT</Tag>
          ) : cred.data === undefined ? (
            <Dots />
          ) : cred.data.exists ? (
            <span className="num text-[0.75rem]">
              {APASS_STATUS[cred.data.status] ?? cred.data.status} · tier {cred.data.tier}
            </span>
          ) : (
            <span className="num text-[0.75rem] text-[var(--color-refuse)]">exists = false</span>
          )}
        </Field>

        <Field label="checkParty">
          {check.error ? (
            <Tag tone="deny">RPC FAULT</Tag>
          ) : check.data === undefined ? (
            <Dots />
          ) : (
            <span
              className={`num text-[0.75rem] ${ok ? "text-[var(--color-teal)]" : "text-[var(--color-refuse)]"}`}
            >
              ({String(ok)}, {code}){code ? ` · ${refusalName(code)}` : ""}
            </span>
          )}
        </Field>

        <Field label="isProtocolRegistered">
          {registered.error ? (
            <Tag tone="deny">RPC FAULT</Tag>
          ) : registered.data === undefined ? (
            <Dots />
          ) : (
            <span
              className={`num text-[0.75rem] ${
                registered.data ? "text-[var(--color-teal)]" : "text-[var(--color-bone-dim)]"
              }`}
            >
              {String(registered.data)}
            </span>
          )}
        </Field>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="leading-none">
      <div className="lbl-micro mb-1.5">{label}</div>
      {children}
    </div>
  );
}

function Dots() {
  return <span className="num text-[0.75rem] text-[var(--color-bone-ghost)] sp-pulse">······</span>;
}
