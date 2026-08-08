"use client";

import type { ReactNode } from "react";
import { ScreenHead } from "@/components/ScreenHead";
import { Amount, Note, Panel, Tag } from "@/components/primitives";
import { Utilization } from "@/components/pool/Utilization";
import { LenderDesk } from "@/components/pool/LenderDesk";
import { PoolCredential } from "@/components/compliance/PoolCredential";
import { ASSET_SYMBOL, CONTRACTS, SHARE_SYMBOL } from "@/lib/contracts";
import { bpsToPercent, shortError } from "@/lib/format";
import { useConvertToAssets, usePoolDecimals, usePoolScalar } from "@/lib/reads";
import { Addr } from "@/components/primitives";
import type { ReadState } from "@/lib/types";

export default function PoolScreen() {
  const totalAssets = usePoolScalar("totalAssets");
  const available = usePoolScalar("availableLiquidity");
  const outstanding = usePoolScalar("outstandingPrincipal");
  const utilization = usePoolScalar("utilizationBps");
  const lifetimeInterest = usePoolScalar("lifetimeInterest");
  const lifetimeLosses = usePoolScalar("lifetimeLosses");
  const maxUtilization = usePoolScalar("maxUtilizationBps");
  const totalSupply = usePoolScalar("totalSupply");

  const shareDecimals = usePoolDecimals();
  // One whole share, in the vault's own share decimals.
  const oneShare = shareDecimals.data !== undefined ? 10n ** BigInt(shareDecimals.data) : undefined;
  const sharePrice = useConvertToAssets(oneShare);

  return (
    <div className="space-y-4">
      <ScreenHead
        title="Pool"
        blurb="The supply side: verified capital lent to verified borrowers. Loans are unsecured beyond a partial collateral posting, so a write-off is a real loss — absorbed by the share price, with no reserve to hide it in."
      />

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,25rem)]">
        <div className="min-w-0 space-y-4">
          {/* ---- the balance sheet -------------------------------------- */}
          <Panel
            label="Balance sheet"
            sub="StandingPool — ERC-4626 over aUSDC"
            right={<Addr address={CONTRACTS.standingPool} head={8} tail={6} tone="dim" />}
            bodyClass="p-0"
          >
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3">
              <Stat
                label="Total assets"
                note="idle balance plus principal out on loan"
                read={totalAssets}
                big
              />
              <Stat
                label="Available liquidity"
                note="lendable and redeemable right now"
                read={available}
                big
              />
              <Stat
                label="Outstanding principal"
                note="currently on borrowers' books"
                read={outstanding}
                big
              />
              <Stat
                label="Lifetime interest"
                note="returned to depositors since inception"
                read={lifetimeInterest}
                tone="teal"
              />
              <Stat
                label="Lifetime losses"
                note="principal written off since inception"
                read={lifetimeLosses}
                tone="refuse"
              />
              <Stat
                label="Shares outstanding"
                note={SHARE_SYMBOL}
                read={totalSupply}
                decimals={shareDecimals.data}
                unit={SHARE_SYMBOL}
              />
            </div>

            <div className="grid grid-cols-1 border-t border-[var(--color-line)] lg:grid-cols-2">
              <div className="border-b border-[var(--color-line)] p-4 lg:border-b-0 lg:border-r">
                <Utilization bps={utilization.data} ceilingBps={maxUtilization.data} />
                <p className="mt-3 text-[0.75rem] leading-relaxed text-[var(--color-bone-faint)]">
                  {utilization.data !== undefined && maxUtilization.data !== undefined ? (
                    <>
                      {bpsToPercent(utilization.data)} of pool assets are out on loan against a
                      self-imposed ceiling of {bpsToPercent(maxUtilization.data, 0)}. The ceiling
                      bounds how much of the book a run of defaults can touch, and keeps redemption
                      liquid.
                    </>
                  ) : (
                    "Reading utilization."
                  )}
                </p>
              </div>

              <div className="p-4">
                <div className="mb-2 flex items-baseline justify-between">
                  <span className="lbl">Assets per share</span>
                  {sharePrice.error ? (
                    <Tag tone="deny">RPC FAULT</Tag>
                  ) : sharePrice.data !== undefined ? (
                    <Amount value={sharePrice.data} size="lg" />
                  ) : (
                    <span className="num text-[var(--color-bone-ghost)] sp-pulse">······</span>
                  )}
                </div>
                <p className="text-[0.75rem] leading-relaxed text-[var(--color-bone-faint)]">
                  <span className="num">convertToAssets(1 share)</span> — the vault carries{" "}
                  {shareDecimals.data ?? "…"} share decimals against the asset&apos;s 6, an
                  offset that makes the first deposit un-grief-able. A default lands here directly:
                  losses reduce total assets, so the share price is where depositors see them.
                </p>
              </div>
            </div>
          </Panel>

          <Panel label="What a depositor is exposed to" sub="plainly stated">
            <Note>
              Deposits fund under-collateralized loans. Every approved borrower posts less than they
              draw, and the difference is secured by a bank-verified credential rather than by
              assets. When a borrower fails to repay, anyone may write the loan off after the grace
              period; the collateral is recovered, the shortfall is booked against{" "}
              <span className="num">totalAssets</span>, and the share price falls for every
              depositor in proportion. There is no insurance fund and no socialised backstop —{" "}
              <span className="num">lifetimeLosses</span> above is the whole record.
            </Note>
          </Panel>
        </div>

        <div className="min-w-0 space-y-4">
          <LenderDesk />
          <PoolCredential />
        </div>
      </div>
    </div>
  );
}

function Stat({
  label,
  note,
  read,
  big = false,
  tone = "normal",
  decimals,
  unit = ASSET_SYMBOL,
}: {
  label: string;
  note: string;
  read: ReadState<bigint>;
  big?: boolean;
  tone?: "normal" | "teal" | "refuse";
  decimals?: number;
  unit?: string;
}) {
  let body: ReactNode;
  if (read.error) {
    body = (
      <span className="chip chip-deny cursor-help" title={shortError(read.error)}>
        RPC FAULT
      </span>
    );
  } else if (read.data === undefined) {
    body = <span className="num text-[var(--color-bone-ghost)] sp-pulse">······</span>;
  } else {
    body = (
      <Amount
        value={read.data}
        size={big ? "lg" : "md"}
        tone={read.data === 0n ? "dim" : tone}
        decimals={decimals}
        unit={unit}
      />
    );
  }

  return (
    <div className="border-b border-r border-[var(--color-line)] p-4">
      <div className="lbl mb-2">{label}</div>
      <div className="min-h-[1.6rem]">{body}</div>
      <div className="lbl-micro mt-2 !tracking-[0.08em] normal-case">{note}</div>
    </div>
  );
}
