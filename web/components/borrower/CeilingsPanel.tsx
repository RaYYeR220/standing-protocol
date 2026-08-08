"use client";

import { Amount, Note, Panel, Row } from "../primitives";
import { durationLabel } from "@/lib/format";
import {
  useMaxCreditLine,
  useMaxLoanPrincipal,
  useMaxTermSeconds,
  useMinLoanPrincipal,
} from "@/lib/reads";

/**
 * The ceilings, read from the deployment. They are immutable: an operator may make
 * the contract stricter, nobody can make it more generous.
 */
export function CeilingsPanel() {
  const maxLoanPrincipal = useMaxLoanPrincipal();
  const maxCreditLine = useMaxCreditLine();
  const maxTermSeconds = useMaxTermSeconds();
  const minLoanPrincipal = useMinLoanPrincipal();

  return (
    <Panel label="Hard ceilings" sub="immutable — fixed at deployment" bodyClass="p-0">
      <div className="px-4 py-1">
        <Row label="Max loan principal" note="maxLoanPrincipal">
          {maxLoanPrincipal.data !== undefined ? (
            <Amount value={maxLoanPrincipal.data} size="sm" />
          ) : (
            <span className="num text-[var(--color-bone-ghost)]">······</span>
          )}
        </Row>
        <Row label="Max credit line" note="maxCreditLine — per identity, not per wallet">
          {maxCreditLine.data !== undefined ? (
            <Amount value={maxCreditLine.data} size="sm" />
          ) : (
            <span className="num text-[var(--color-bone-ghost)]">······</span>
          )}
        </Row>
        <Row label="Min loan principal" note="MIN_LOAN_PRINCIPAL — a floor against manufactured history">
          {minLoanPrincipal.data !== undefined ? (
            <Amount value={minLoanPrincipal.data} size="sm" />
          ) : (
            <span className="num text-[var(--color-bone-ghost)]">······</span>
          )}
        </Row>
        <Row label="Max term" note="maxTermSeconds">
          {maxTermSeconds.data !== undefined ? (
            <span className="num text-[0.8125rem]">
              {durationLabel(Number(maxTermSeconds.data))}
            </span>
          ) : (
            <span className="num text-[var(--color-bone-ghost)]">······</span>
          )}
        </Row>
        <Row label="Min term" note="MIN_TERM_SECONDS">
          <span className="num text-[0.8125rem]">1d</span>
        </Row>
        <Row label="APR band" note="MIN_APR_BPS — MAX_APR_BPS">
          <span className="num text-[0.8125rem]">5.00% — 25.00%</span>
        </Row>
      </div>
      <div className="border-t border-[var(--color-line)] p-4">
        <Note>
          No role, no signature and no upgrade path raises these. They sit above the scoring curve,
          so a bug in underwriting is bounded by arithmetic rather than by governance.
        </Note>
      </div>
    </Panel>
  );
}
