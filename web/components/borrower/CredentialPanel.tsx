"use client";

import type { Address } from "viem";
import { Amount, Addr, Bar, Empty, Fault, Hash, Note, Panel, Row, Stamp, Tag } from "../primitives";
import { APASS_STATUS, CONTRACTS, ZERO_HASH } from "@/lib/contracts";
import { truncateMid } from "@/lib/format";
import { useAssetBalance, useCanonicalIdentity, useCredential } from "@/lib/reads";

/**
 * The A-Pass, read straight off the registry through CreditManager.credentialOf.
 * "No credential" is a state the protocol is designed around, so it is rendered as
 * a finding rather than as an error.
 */
export function CredentialPanel({ subject }: { subject: Address }) {
  const cred = useCredential(subject);
  const balance = useAssetBalance(subject);
  const canonical = useCanonicalIdentity(
    cred.data?.kycHash && cred.data.kycHash !== ZERO_HASH ? cred.data.kycHash : undefined,
  );

  const c = cred.data;
  const nowSec = Math.floor(Date.now() / 1000);
  const expired = c ? Number(c.expiresAt) <= nowSec : false;
  const live = c ? c.exists && c.status === 1 && !expired : false;

  const headerTag = cred.error ? (
    <Tag tone="deny">RPC FAULT</Tag>
  ) : !c ? (
    <Tag tone="idle">READING</Tag>
  ) : live ? (
    <Tag tone="pass">LIVE</Tag>
  ) : (
    <Tag tone="deny">NOT USABLE</Tag>
  );

  return (
    <Panel
      label="A-Pass"
      sub={`credentialOf(${truncateMid(subject, 6, 4)})`}
      right={headerTag}
      bodyClass="p-0"
    >
      {cred.error ? (
        <div className="p-4">
          <Fault error={cred.error} what="CreditManager.credentialOf" />
        </div>
      ) : !c ? (
        <div className="p-4">
          <Empty>Reading credential from the A-Pass registry</Empty>
        </div>
      ) : !c.exists ? (
        <NoCredential subject={subject} />
      ) : (
        <div className="divide-y divide-[var(--color-line)]">
          <div className="px-4 py-1">
            <Row label="Exists">
              <Tag tone="pass">TRUE</Tag>
            </Row>
            <Row label="Status" note={`code ${c.status}`}>
              {c.status === 1 ? (
                <Tag tone="pass">{APASS_STATUS[c.status] ?? "Unknown"}</Tag>
              ) : (
                <Tag tone="deny">{APASS_STATUS[c.status] ?? `Unknown (${c.status})`}</Tag>
              )}
            </Row>
            <Row label="Tier" note="set by the issuing institution, 0–99">
              <span className="num text-[1.0625rem]">
                {c.tier}
                <span className="text-[var(--color-bone-faint)]"> / 99</span>
              </span>
            </Row>
            <Row label="Sub-tier" note="institution-defined, 0–99">
              <span className="num text-[1.0625rem]">
                {c.subTier}
                <span className="text-[var(--color-bone-faint)]"> / 99</span>
              </span>
            </Row>
            <Row label="Group">
              <span className="num text-[0.75rem] text-[var(--color-bone-dim)]">{c.group}</span>
            </Row>
            <Row label="Sub-group">
              <span className="num text-[0.75rem] text-[var(--color-bone-dim)]">{c.subGroup}</span>
            </Row>
            <Row label="Issued">
              <Stamp seconds={c.issuedAt} />
            </Row>
            <Row label="Expires">
              <span className="flex items-center gap-2">
                {expired ? <Tag tone="deny">EXPIRED</Tag> : null}
                <Stamp seconds={c.expiresAt} />
              </span>
            </Row>
          </div>

          <div className="space-y-3 px-4 py-3">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="lbl">KYC hash</span>
              <Hash value={c.kycHash} head={18} tail={12} />
            </div>
            {c.previousKycHash !== ZERO_HASH ? (
              <div className="border-l-2 border-[var(--color-teal-deep)] pl-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="lbl">Supersedes</span>
                  <Hash value={c.previousKycHash} head={18} tail={12} />
                </div>
                <Note>
                  This credential replaced an earlier one. The registry unions the two hashes into a
                  single identity record, so re-verifying does not shed a default.
                </Note>
              </div>
            ) : null}
            {canonical.data && canonical.data !== c.kycHash ? (
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="lbl">Canonical identity</span>
                <Hash value={canonical.data} head={18} tail={12} />
              </div>
            ) : null}
          </div>

          <div className="px-4 py-1">
            <Row label="Verified balance" note="aUSDC held by this wallet">
              {balance.error ? (
                <Tag tone="deny">RPC FAULT</Tag>
              ) : balance.data === undefined ? (
                <span className="num text-[var(--color-bone-ghost)] sp-pulse">······</span>
              ) : (
                <Amount value={balance.data} />
              )}
            </Row>
            <Row label="Tier weight" note="tier × 300 / 99 in the identity component">
              <div className="w-32">
                <Bar value={c.tier} max={99} />
              </div>
            </Row>
          </div>
        </div>
      )}
    </Panel>
  );
}

function NoCredential({ subject }: { subject: Address }) {
  return (
    <div className="p-4">
      <div className="border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-5">
        <div className="flex flex-wrap items-center gap-3">
          <span className="h-8 w-1 shrink-0 bg-[var(--color-refuse)]" aria-hidden />
          <h3 className="num text-[1.25rem] tracking-[-0.01em] text-[var(--color-refuse)]">
            NO CREDENTIAL ON RECORD
          </h3>
        </div>
        <p className="num mt-3 text-[0.75rem] text-[var(--color-bone-dim)]">
          credentialOf({truncateMid(subject, 8, 6)}) → exists = <span className="text-[var(--color-refuse)]">false</span>
        </p>
        <p className="mt-3 max-w-[64ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
          The Cleanverse A-Pass registry holds no record for this address. There is no verified
          identity behind it, so there is nothing to underwrite against and nobody to pursue after a
          write-off. The score is zero by construction — identity is the collateral here, and an
          absent credential is not a discount on the terms, it is a refusal.
        </p>
        <div className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2 border-t border-[var(--color-refuse-deep)] pt-3">
          <span className="lbl">Registry</span>
          <Addr address={CONTRACTS.apassRegistry} tone="dim" head={10} tail={8} />
          <span className="lbl">Subject</span>
          <Addr address={subject} tone="refuse" head={10} tail={8} />
        </div>
      </div>
    </div>
  );
}
