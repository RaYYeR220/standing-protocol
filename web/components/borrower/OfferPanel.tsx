"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { creditManagerAbi, erc20Abi } from "@/lib/abi";
import { ASSET_SYMBOL, CONTRACTS, REFUSAL_PROSE, refusalName, SCORING } from "@/lib/contracts";
import { bpsToPercent, durationLabel, formatTimestamp, formatUnits6, shortError } from "@/lib/format";
import { useAllowance, useAssetBalance } from "@/lib/reads";
import type { Quote } from "@/lib/types";
import { explorerTx } from "@/lib/chain";
import { Amount, Empty, Fault, Note, Panel, Pct, Row, Tag } from "../primitives";

const TERM_PRESETS: { days: number; label: string }[] = [
  { days: 7, label: "1 wk" },
  { days: 30, label: "1 mo" },
  { days: 90, label: "3 mo" },
  { days: 180, label: "6 mo" },
  { days: 365, label: "1 yr" },
];

type Props = {
  subject: Address;
  quote: { data: Quote | undefined; error: unknown };
  amount: bigint;
  amountInput: string;
  setAmountInput: (v: string) => void;
  termDays: number;
  setTermDays: (v: number) => void;
  minLoanPrincipal: bigint | undefined;
  maxLoanPrincipal: bigint | undefined;
  maxTermSeconds: bigint | undefined;
  availableLiquidity: bigint | undefined;
};

/**
 * The offer, and the draw. Terms come from a live quote() against the same block
 * the contract would enforce on, so what is shown is what would happen.
 */
export function OfferPanel({
  subject,
  quote,
  amount,
  amountInput,
  setAmountInput,
  termDays,
  setTermDays,
  minLoanPrincipal,
  maxLoanPrincipal,
  maxTermSeconds,
  availableLiquidity,
}: Props) {
  const { address: connected } = useAccount();
  const isSelf = Boolean(connected && connected.toLowerCase() === subject.toLowerCase());

  const allowance = useAllowance(isSelf ? connected : undefined, CONTRACTS.creditManager);
  const balance = useAssetBalance(isSelf ? connected : undefined);

  const approve = useWriteContract();
  const open = useWriteContract();
  const approveRc = useWaitForTransactionReceipt({ hash: approve.data });
  const openRc = useWaitForTransactionReceipt({ hash: open.data });

  const q = quote.data;
  const termSeconds = BigInt(termDays * 86_400);

  const collateralBps = useMemo(() => {
    if (!q || amount === 0n) return null;
    return Number((q.collateralRequired * 10_000n) / amount);
  }, [q, amount]);

  const needsApproval =
    q !== undefined &&
    allowance.data !== undefined &&
    q.collateralRequired > 0n &&
    allowance.data < q.collateralRequired;

  /* ---- preflight: the contract's own conditions, evaluated client-side ---- */
  const checks = useMemo(() => {
    if (!q) return [];
    const out: { label: string; ok: boolean; detail: string }[] = [];

    out.push({
      label: "Compliance gate",
      ok: q.refusal === 0,
      detail:
        q.refusal === 0
          ? "checkTransfer(pool → borrower) permitted"
          : `refused — ${q.refusal} ${refusalName(q.refusal)}`,
    });
    out.push({
      label: "Minimum standing",
      ok: Number(q.score) >= SCORING.MIN_SCORE,
      detail: `score ${q.score} against a floor of ${SCORING.MIN_SCORE}`,
    });
    if (minLoanPrincipal !== undefined) {
      out.push({
        label: "Minimum principal",
        ok: amount >= minLoanPrincipal,
        detail: `MIN_LOAN_PRINCIPAL is ${formatUnits6(minLoanPrincipal)} ${ASSET_SYMBOL}`,
      });
    }
    if (maxLoanPrincipal !== undefined) {
      out.push({
        label: "Loan ceiling",
        ok: amount <= maxLoanPrincipal,
        detail: `maxLoanPrincipal is ${formatUnits6(maxLoanPrincipal)} ${ASSET_SYMBOL}`,
      });
    }
    out.push({
      label: "Credit headroom",
      ok: amount > 0n && amount <= q.maxDrawNow,
      detail:
        q.maxDrawNow === 0n && availableLiquidity === 0n
          ? "maxDrawNow is 0 — the pool holds no liquidity to lend"
          : `maxDrawNow is ${formatUnits6(q.maxDrawNow)} ${ASSET_SYMBOL}`,
    });
    if (maxTermSeconds !== undefined) {
      out.push({
        label: "Term bounds",
        ok: termSeconds >= 86_400n && termSeconds <= maxTermSeconds,
        detail: `1 day ≤ term ≤ ${durationLabel(Number(maxTermSeconds))}`,
      });
    }
    return out;
  }, [q, amount, termSeconds, minLoanPrincipal, maxLoanPrincipal, maxTermSeconds, availableLiquidity]);

  const allClear = checks.length > 0 && checks.every((c) => c.ok);

  if (quote.error) {
    return (
      <Panel label="Credit Offer" sub="quote()">
        <Fault error={quote.error} what="CreditManager.quote" />
      </Panel>
    );
  }

  return (
    <Panel
      label="Credit Offer"
      sub="terms the contract will enforce, at this block"
      right={
        q ? (
          q.approved ? (
            <Tag tone="pass">APPROVED</Tag>
          ) : (
            <Tag tone="deny">NOT APPROVED</Tag>
          )
        ) : (
          <Tag tone="idle">READING</Tag>
        )
      }
      bodyClass="p-0"
    >
      {/* ---- request ------------------------------------------------------ */}
      <div className="grid grid-cols-1 gap-4 border-b border-[var(--color-line)] p-4 md:grid-cols-2">
        <div>
          <label className="lbl mb-2 block" htmlFor="principal">
            Principal requested
          </label>
          <div className="relative">
            <input
              id="principal"
              className="field pr-16 text-[1rem]"
              inputMode="decimal"
              spellCheck={false}
              value={amountInput}
              onChange={(e) => setAmountInput(e.target.value)}
              placeholder="0.000000"
            />
            <span className="lbl-micro pointer-events-none absolute right-3 top-1/2 -translate-y-1/2">
              {ASSET_SYMBOL}
            </span>
          </div>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {q && q.maxDrawNow > 0n ? (
              <button
                className="btn !px-2 !py-1"
                onClick={() => setAmountInput(formatUnits6(q.maxDrawNow))}
              >
                Max draw
              </button>
            ) : null}
            {["100", "1000", "10000"].map((v) => (
              <button key={v} className="btn !px-2 !py-1" onClick={() => setAmountInput(v)}>
                {Number(v).toLocaleString("en-US")}
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="lbl mb-2 block" htmlFor="term">
            Term
          </label>
          <div className="relative">
            <input
              id="term"
              className="field pr-16 text-[1rem]"
              inputMode="numeric"
              value={termDays}
              onChange={(e) => {
                const n = Number(e.target.value.replace(/\D/g, ""));
                setTermDays(Number.isFinite(n) ? n : 0);
              }}
            />
            <span className="lbl-micro pointer-events-none absolute right-3 top-1/2 -translate-y-1/2">
              DAYS
            </span>
          </div>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {TERM_PRESETS.map((p) => (
              <button
                key={p.days}
                className={`btn !px-2 !py-1 ${termDays === p.days ? "btn-key" : ""}`}
                title={`${p.days} days`}
                onClick={() => setTermDays(p.days)}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {!q ? (
        <div className="p-4">
          <Empty>Underwriting</Empty>
        </div>
      ) : (
        <>
          {/* ---- terms ------------------------------------------------------ */}
          <div className="grid grid-cols-1 gap-x-8 px-4 py-1 lg:grid-cols-2">
            <Row label="Credit line" note="maximum this identity may owe at once">
              <Amount value={q.creditLine} />
            </Row>
            <Row label="Already drawn" note="across every wallet of the same identity">
              <Amount value={q.alreadyDrawn} tone={q.alreadyDrawn > 0n ? "normal" : "dim"} />
            </Row>
            <Row label="Max draw now" note="line, less drawn, capped by ceiling and pool liquidity">
              <Amount value={q.maxDrawNow} tone={q.maxDrawNow > 0n ? "teal" : "refuse"} />
            </Row>
            <Row label="APR" note="falls from 25% to 5% as standing rises">
              <Pct bps={q.aprBps} size="lg" tone={q.aprBps > 0n ? "normal" : "dim"} />
            </Row>
            <Row label="Interest for term" note={`${termDays} days at the rate above`}>
              <Amount value={q.interestForTerm} />
            </Row>
            <Row label="Due at maturity" note="principal plus interest, in one payment">
              <Amount value={amount + q.interestForTerm} />
            </Row>
            <Row label="Matures" note="term measured from the opening block">
              <span className="num text-[0.75rem]">
                {formatTimestamp(Math.floor(Date.now() / 1000) + termDays * 86_400)}
              </span>
            </Row>
            <Row label="Grace period" note="before the loan can be written off by anyone">
              <span className="num text-[0.8125rem]">3 days</span>
            </Row>
          </div>

          {/* ---- the collateral statement ----------------------------------- */}
          <div className="border-y border-[var(--color-line)] bg-[var(--color-panel-sunk)] p-4">
            <div className="flex flex-wrap items-end justify-between gap-4">
              <div>
                <div className="lbl mb-2">Collateral required</div>
                <Amount value={q.collateralRequired} size="xl" tone="teal" />
              </div>
              <div className="text-right">
                <div className="lbl mb-2">As a share of principal</div>
                <span className="num text-[1.75rem] leading-none text-[var(--color-bone)]">
                  {collateralBps === null ? "—" : bpsToPercent(collateralBps)}
                </span>
              </div>
            </div>
            {amount > 0n ? (
              <p className="mt-4 max-w-[72ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
                On a principal of{" "}
                <span className="num text-[var(--color-bone)]">
                  {formatUnits6(amount)} {ASSET_SYMBOL}
                </span>{" "}
                the borrower posts{" "}
                <span className="num text-[var(--color-teal)]">
                  {formatUnits6(q.collateralRequired)} {ASSET_SYMBOL}
                </span>
                . That is{" "}
                <strong className="font-semibold text-[var(--color-bone)]">
                  less than the principal
                </strong>{" "}
                — the borrower receives{" "}
                <span className="num text-[var(--color-bone)]">
                  {formatUnits6(amount - q.collateralRequired)} {ASSET_SYMBOL}
                </span>{" "}
                more than they put up. The gap is carried by the credential: a write-off is recorded
                against the bank-verified identity, not the wallet, so it follows the borrower to
                every wallet they ever open.
              </p>
            ) : (
              <Note>Enter a principal to see the collateral the contract would require.</Note>
            )}
            <div className="mt-3 border-t border-[var(--color-line)] pt-3">
              <span className="lbl-micro">
                collateral falls from {SCORING.MAX_COLLATERAL_BPS / 100}% of principal at the floor
                to 0% at a perfect score — every approved loan is under-collateralized by
                construction
              </span>
            </div>
          </div>

          {/* ---- preflight + draw ------------------------------------------- */}
          <div className="grid grid-cols-1 gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
            <div>
              <div className="lbl mb-2.5">Pre-flight — the contract&apos;s own conditions</div>
              <ul className="divide-y divide-[var(--color-line)] border border-[var(--color-line)]">
                {checks.map((c) => (
                  <li key={c.label} className="flex items-center gap-3 px-3 py-2">
                    <span className="w-[9.5rem] shrink-0">
                      <span className="lbl">{c.label}</span>
                    </span>
                    <span className="flex-1 truncate text-[0.75rem] text-[var(--color-bone-faint)]">
                      {c.detail}
                    </span>
                    <Tag tone={c.ok ? "pass" : "deny"}>{c.ok ? "OK" : "BLOCK"}</Tag>
                  </li>
                ))}
              </ul>

              {q.refusal !== 0 ? (
                <div className="mt-3 border-l-2 border-[var(--color-refuse)] bg-[var(--color-refuse-wash)] p-3">
                  <div className="num text-[0.8125rem] text-[var(--color-refuse)]">
                    Refusal {q.refusal} · {refusalName(q.refusal)}
                  </div>
                  <p className="mt-1.5 max-w-[62ch] text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
                    {REFUSAL_PROSE[refusalName(q.refusal)]}
                  </p>
                </div>
              ) : null}
            </div>

            <div className="lg:border-l lg:border-[var(--color-line)] lg:pl-4">
              <div className="lbl mb-2.5">Draw</div>
              {!isSelf ? (
                <div className="border border-[var(--color-line-lift)] p-3">
                  <p className="text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
                    You are examining an address other than the connected wallet.{" "}
                    <span className="num">open()</span> draws against{" "}
                    <span className="num">msg.sender</span>, so connect as this address to borrow.
                  </p>
                </div>
              ) : (
                <div className="space-y-2.5">
                  <Row label="Wallet balance" dense>
                    {balance.data !== undefined ? (
                      <Amount value={balance.data} size="sm" />
                    ) : (
                      <span className="num text-[var(--color-bone-ghost)]">······</span>
                    )}
                  </Row>
                  <Row label="Collateral allowance" dense>
                    {allowance.data !== undefined ? (
                      <Amount value={allowance.data} size="sm" />
                    ) : (
                      <span className="num text-[var(--color-bone-ghost)]">······</span>
                    )}
                  </Row>

                  <button
                    className="btn w-full"
                    disabled={!needsApproval || approve.isPending || approveRc.isLoading}
                    onClick={() =>
                      approve.writeContract({
                        address: CONTRACTS.verifiedAsset,
                        abi: erc20Abi,
                        functionName: "approve",
                        args: [CONTRACTS.creditManager, q.collateralRequired],
                      })
                    }
                  >
                    {approve.isPending || approveRc.isLoading
                      ? "Approving…"
                      : needsApproval
                        ? "1 · Approve collateral"
                        : "1 · Collateral approved"}
                  </button>

                  <button
                    className="btn btn-key w-full"
                    disabled={
                      !allClear || needsApproval || open.isPending || openRc.isLoading
                    }
                    onClick={() =>
                      open.writeContract({
                        address: CONTRACTS.creditManager,
                        abi: creditManagerAbi,
                        functionName: "open",
                        args: [amount, termSeconds],
                      })
                    }
                  >
                    {open.isPending || openRc.isLoading ? "Opening…" : "2 · Open loan"}
                  </button>

                  <TxState label="approve" write={approve} receipt={approveRc} />
                  <TxState label="open" write={open} receipt={openRc} />
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </Panel>
  );
}

type WriteLike = { error: unknown; data: `0x${string}` | undefined };
type ReceiptLike = { isLoading: boolean; isSuccess: boolean; error: unknown };

function TxState({
  label,
  write,
  receipt,
}: {
  label: string;
  write: WriteLike;
  receipt: ReceiptLike;
}) {
  const err = write.error ?? receipt.error;
  if (err) {
    return (
      <div className="border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-2">
        <div className="lbl !text-[var(--color-refuse)]">{label} reverted</div>
        <p className="num mt-1 break-words text-[0.625rem] text-[var(--color-refuse)] opacity-85">
          {shortError(err)}
        </p>
      </div>
    );
  }
  if (!write.data) return null;
  return (
    <a
      href={explorerTx(write.data)}
      target="_blank"
      rel="noreferrer"
      className="flex items-center justify-between border border-[var(--color-line-lift)] px-2 py-1.5 hover:border-[var(--color-teal)]"
    >
      <span className="lbl">{label}</span>
      <span className="num text-[0.625rem] text-[var(--color-teal)]">
        {receipt.isLoading ? "PENDING" : receipt.isSuccess ? "CONFIRMED" : "SENT"}
      </span>
    </a>
  );
}
