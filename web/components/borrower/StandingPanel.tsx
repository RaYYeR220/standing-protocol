"use client";

import type { ReactNode } from "react";
import { Colonnade } from "../Colonnade";
import { Amount, Bar, Empty, Fault, Note, Panel, Tag } from "../primitives";
import { ASSET_LADDER, ASSET_SYMBOL, SCORING } from "@/lib/contracts";
import { formatUnits6, groupDigits } from "@/lib/format";
import type { Credential, History, Quote } from "@/lib/types";

type Props = {
  quote: { data: Quote | undefined; error: unknown };
  credential: Credential | undefined;
  history: History | undefined;
  balance: bigint | undefined;
};

/**
 * The score and every term that produced it. The contract returns the whole
 * breakdown for exactly this reason: a borrower refused credit is entitled to see
 * which input refused them.
 */
export function StandingPanel({ quote, credential, history, balance }: Props) {
  if (quote.error) {
    return (
      <Panel label="Standing" sub="quote(borrower, amount, term)">
        <Fault error={quote.error} what="CreditManager.quote" />
      </Panel>
    );
  }
  const q = quote.data;
  if (!q) {
    return (
      <Panel label="Standing" sub="quote(borrower, amount, term)">
        <Empty>Underwriting</Empty>
      </Panel>
    );
  }

  const b = q.breakdown;
  const score = Number(b.score);
  const clears = score >= SCORING.MIN_SCORE;
  const shortBy = Math.max(0, SCORING.MIN_SCORE - score);

  const historyGross = Math.min(
    Number(b.repaymentPoints) + Number(b.volumePoints),
    SCORING.HISTORY_MAX,
  );
  const wholeScorePenalty = Math.max(0, Number(b.defaultPenalty) - historyGross);

  // StandingMath returns an all-zero breakdown when the credential is not live, so
  // the derivations must say that rather than compute against a zero issuedAt.
  const nowSec = Math.floor(Date.now() / 1000);
  const credLive = Boolean(
    credential && credential.exists && credential.status === 1 && Number(credential.expiresAt) > nowSec,
  );
  const tenureDays =
    credential && credential.issuedAt > 0n
      ? Math.max(0, Math.floor((nowSec - Number(credential.issuedAt)) / 86_400))
      : 0;

  const repaidCounted = history ? Math.min(history.loansRepaid, SCORING.REPAID_CAP) : 0;
  const volumeUnits = history
    ? Math.min(Number(history.totalRepaid / 1_000_000_000n), SCORING.VOLUME_CAP)
    : 0;

  const nextRung = balance !== undefined ? ASSET_LADDER.find((r) => balance < r.threshold) : undefined;

  return (
    <Panel
      label="Standing"
      sub="StandingMath.score — pure, on-chain, no model in the path"
      right={
        clears ? (
          <Tag tone="pass">CLEARS FLOOR</Tag>
        ) : (
          <Tag tone="deny">BELOW FLOOR</Tag>
        )
      }
      bodyClass="p-0"
    >
      {/* ---- the colonnade ------------------------------------------------ */}
      <div className="grid grid-cols-1 gap-5 border-b border-[var(--color-line)] p-4 lg:grid-cols-[minmax(0,1fr)_13rem]">
        <div className="order-2 lg:order-1">
          <Colonnade score={score} min={SCORING.MIN_SCORE} max={SCORING.MAX_SCORE} />
          <div className="mt-2 flex justify-between">
            <span className="lbl-micro">0</span>
            <span className="lbl-micro">one pillar = 40 pts</span>
            <span className="lbl-micro">{SCORING.MAX_SCORE}</span>
          </div>
        </div>

        <div className="order-1 flex flex-col justify-end gap-3 lg:order-2 lg:border-l lg:border-[var(--color-line)] lg:pl-5">
          <div>
            <div className="lbl-micro mb-2">Standing score</div>
            <div className="flex items-baseline gap-1.5">
              <span
                className={`num text-[3rem] leading-[0.85] tracking-[-0.04em] ${
                  clears ? "text-[var(--color-teal)]" : "text-[var(--color-refuse)]"
                }`}
              >
                {score}
              </span>
              <span className="num text-[1rem] text-[var(--color-bone-faint)]">/ 1000</span>
            </div>
          </div>
          <div className="border-t border-[var(--color-line)] pt-3">
            {clears ? (
              <p className="text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
                Clears the {SCORING.MIN_SCORE}-point floor by{" "}
                <span className="num text-[var(--color-teal)]">{score - SCORING.MIN_SCORE}</span>.
                Terms below are the ones the contract will enforce.
              </p>
            ) : (
              <p className="text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
                Short of the floor by{" "}
                <span className="num text-[var(--color-refuse)]">{shortBy}</span> points. Below{" "}
                {SCORING.MIN_SCORE} no amount of collateral buys a loan — identity is the entry
                ticket, not a discount.
              </p>
            )}
          </div>
        </div>
      </div>

      {/* ---- the itemised ledger ------------------------------------------ */}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[42rem] border-collapse">
          <thead>
            <tr className="border-b border-[var(--color-line)] bg-[var(--color-panel-sunk)]">
              <Th className="w-[15rem]">Component</Th>
              <Th>Derivation from on-chain state</Th>
              <Th align="right" className="w-[6rem]">
                Points
              </Th>
              <Th align="right" className="w-[5rem]">
                Ceiling
              </Th>
              <Th className="w-[7rem]">Against cap</Th>
            </tr>
          </thead>
          <tbody>
            {!credLive ? (
              <tr className="border-b border-[var(--color-line)] bg-[var(--color-refuse-wash)]">
                <td className="px-4 py-2.5" colSpan={5}>
                  <span className="num text-[0.75rem] text-[var(--color-refuse)]">
                    Credential is not live at this block.
                  </span>{" "}
                  <span className="text-[0.75rem] text-[var(--color-bone-dim)]">
                    StandingMath short-circuits before scoring anything: a missing, frozen or
                    expired A-Pass returns an all-zero breakdown. Every component below is zero for
                    that one reason, not for seven separate ones.
                  </span>
                </td>
              </tr>
            ) : null}

            <GroupRow label="Identity" note="what the issuing bank vouched for" />
            <Line
              name="tierPoints"
              derivation={
                credLive && credential
                  ? `tier ${credential.tier} × 300 ÷ 99`
                  : "no live credential to read a tier from"
              }
              points={Number(b.tierPoints)}
              cap={SCORING.TIER_MAX}
            />
            <Line
              name="subTierPoints"
              derivation={
                credLive && credential
                  ? `sub-tier ${credential.subTier} × 50 ÷ 99`
                  : "no live credential to read a sub-tier from"
              }
              points={Number(b.subTierPoints)}
              cap={SCORING.SUBTIER_MAX}
            />
            <Line
              name="tenurePoints"
              derivation={
                credLive
                  ? `${groupDigits(String(tenureDays))} of 365 days since the credential was issued`
                  : "no live credential, so no tenure to count"
              }
              points={Number(b.tenurePoints)}
              cap={SCORING.TENURE_MAX}
            />
            <Subtotal
              label="identitySubtotal"
              value={Number(b.identitySubtotal)}
              cap={SCORING.IDENTITY_MAX}
            />

            <GroupRow label="History" note="what this identity did with borrowed money" />
            <Line
              name="repaymentPoints"
              derivation={`${repaidCounted} qualifying repayment${repaidCounted === 1 ? "" : "s"} × 25 (counted to a cap of 10)`}
              points={Number(b.repaymentPoints)}
              cap={SCORING.REPAID_CAP * SCORING.REPAID_POINTS}
            />
            <Line
              name="volumePoints"
              derivation={`${volumeUnits} × 1,000 ${ASSET_SYMBOL} repaid × 10${
                history ? ` — ${formatUnits6(history.totalRepaid)} returned lifetime` : ""
              }`}
              points={Number(b.volumePoints)}
              cap={SCORING.VOLUME_CAP * SCORING.VOLUME_POINTS}
            />
            <Line
              name="defaultPenalty"
              derivation={`${history?.loansDefaulted ?? 0} write-off${
                (history?.loansDefaulted ?? 0) === 1 ? "" : "s"
              } × 250 — subtracted, not capped`}
              points={-Number(b.defaultPenalty)}
              cap={0}
              negative
            />
            <Subtotal
              label="historySubtotal"
              value={Number(b.historySubtotal)}
              cap={SCORING.HISTORY_MAX}
            />

            <GroupRow label="Assets" note="verified holdings only — origin is what makes them evidence" />
            <Line
              name="assetPoints"
              derivation={
                !credLive
                  ? "no live credential, so holdings are never reached"
                  : balance !== undefined
                    ? `balance ${formatUnits6(balance)} ${ASSET_SYMBOL} on a base-10 ladder${
                        nextRung
                          ? ` — next rung at ${formatUnits6(nextRung.threshold)} for ${nextRung.points}`
                          : " — top rung"
                      }`
                    : "balance on a base-10 ladder"
              }
              points={Number(b.assetPoints)}
              cap={SCORING.ASSETS_MAX}
            />
            <Subtotal
              label="assetSubtotal"
              value={Number(b.assetSubtotal)}
              cap={SCORING.ASSETS_MAX}
            />

            {wholeScorePenalty > 0 ? (
              <tr className="border-b border-[var(--color-line)] bg-[var(--color-refuse-wash)]">
                <Td className="!text-[var(--color-refuse)]">whole-score penalty</Td>
                <Td className="text-[var(--color-bone-dim)]">
                  a write-off outruns the history bucket and is carried against the total, so a large
                  balance cannot paper over it
                </Td>
                <Td align="right">
                  <span className="num text-[var(--color-refuse)]">−{wholeScorePenalty}</span>
                </Td>
                <Td align="right">
                  <span className="num text-[var(--color-bone-ghost)]">—</span>
                </Td>
                <Td />
              </tr>
            ) : null}

            <tr className="border-t-2 border-[var(--color-line-hot)] bg-[var(--color-panel-sunk)]">
              <Td>
                <span className="lbl !text-[var(--color-bone)]">Score</span>
              </Td>
              <Td className="text-[var(--color-bone-faint)]">
                identity + history + assets, capped at 1000
              </Td>
              <Td align="right">
                <span
                  className={`num text-[1.0625rem] ${
                    clears ? "text-[var(--color-teal)]" : "text-[var(--color-refuse)]"
                  }`}
                >
                  {score}
                </span>
              </Td>
              <Td align="right">
                <span className="num text-[var(--color-bone-faint)]">1000</span>
              </Td>
              <Td>
                <Bar value={score} max={1000} tone={clears ? "teal" : "refuse"} height={4} />
              </Td>
            </tr>
            <tr className="bg-[var(--color-panel-sunk)]">
              <Td>
                <span className="lbl">Minimum standing</span>
              </Td>
              <Td className="text-[var(--color-bone-faint)]">
                StandingMath.MIN_SCORE — the entry ticket
              </Td>
              <Td align="right">
                <span className="num text-[var(--color-bone-dim)]">{SCORING.MIN_SCORE}</span>
              </Td>
              <Td align="right" />
              <Td />
            </tr>
          </tbody>
        </table>
      </div>

      <div className="border-t border-[var(--color-line)] px-4 py-3">
        <Note>
          Every number above came out of a single <span className="num">quote()</span> call. The
          arithmetic is fixed and pure — two callers reading the same block get the same score, and
          nothing off-chain can move it.
        </Note>
      </div>
    </Panel>
  );
}

/* ------------------------------------------------------------------ table bits */

function Th({
  children,
  align = "left",
  className = "",
}: {
  children?: ReactNode;
  align?: "left" | "right";
  className?: string;
}) {
  return (
    <th
      className={`lbl px-4 py-2 ${align === "right" ? "text-right" : "text-left"} ${className}`}
      scope="col"
    >
      {children}
    </th>
  );
}

function Td({
  children,
  align = "left",
  className = "",
}: {
  children?: ReactNode;
  align?: "left" | "right";
  className?: string;
}) {
  return (
    <td
      className={`px-4 py-2 align-middle text-[0.75rem] ${
        align === "right" ? "text-right" : "text-left"
      } ${className}`}
    >
      {children}
    </td>
  );
}

function GroupRow({ label, note }: { label: string; note: string }) {
  return (
    <tr className="border-y border-[var(--color-line)] bg-[var(--color-panel-sunk)]">
      <td className="px-4 py-1.5" colSpan={5}>
        <span className="lbl !text-[var(--color-bone-dim)]">{label}</span>
        <span className="lbl-micro ml-3 !tracking-[0.08em] normal-case">{note}</span>
      </td>
    </tr>
  );
}

function Line({
  name,
  derivation,
  points,
  cap,
  negative = false,
}: {
  name: string;
  derivation: string;
  points: number;
  cap: number;
  negative?: boolean;
}) {
  const zero = points === 0;
  return (
    <tr className="border-b border-[var(--color-line)]">
      <Td>
        <span className="num text-[0.75rem] text-[var(--color-bone-dim)]">{name}</span>
      </Td>
      <Td className="text-[var(--color-bone-faint)]">{derivation}</Td>
      <Td align="right">
        <span
          className={`num ${
            negative && points !== 0
              ? "text-[var(--color-refuse)]"
              : zero
                ? "text-[var(--color-bone-ghost)]"
                : "text-[var(--color-bone)]"
          }`}
        >
          {points}
        </span>
      </Td>
      <Td align="right">
        <span className="num text-[var(--color-bone-ghost)]">{cap ? cap : "—"}</span>
      </Td>
      <Td>
        {cap ? (
          <Bar value={Math.abs(points)} max={cap} tone={zero ? "dim" : negative ? "refuse" : "teal"} />
        ) : null}
      </Td>
    </tr>
  );
}

function Subtotal({ label, value, cap }: { label: string; value: number; cap: number }) {
  return (
    <tr className="border-b border-[var(--color-line)]">
      <Td>
        <span className="num text-[0.75rem] text-[var(--color-bone)]">{label}</span>
      </Td>
      <Td className="text-[var(--color-bone-faint)]">capped at {cap}</Td>
      <Td align="right">
        <span className="num text-[var(--color-bone)]">{value}</span>
      </Td>
      <Td align="right">
        <span className="num text-[var(--color-bone-ghost)]">{cap}</span>
      </Td>
      <Td>
        <Bar value={value} max={cap} tone={value === 0 ? "dim" : "teal"} height={4} />
      </Td>
    </tr>
  );
}
