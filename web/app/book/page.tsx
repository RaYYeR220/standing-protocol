"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { ScreenHead } from "@/components/ScreenHead";
import { Addr, Amount, Empty, Fault, Hash, Note, Panel, Tag } from "@/components/primitives";
import { useLoanBook } from "@/components/book/useLoanBook";
import { creditManagerAbi } from "@/lib/abi";
import { GRACE_PERIOD_SECONDS, LOAN_STATUS } from "@/lib/contracts";
import { bpsToPercent, formatTimestamp, relativeTime, shortError } from "@/lib/format";
import { useNetwork } from "@/lib/network";
import { useSubject } from "@/lib/subject";
import type { LoanRow } from "@/lib/types";

export default function LoanBookScreen() {
  const { subject } = useSubject();
  const [onlySubject, setOnlySubject] = useState(false);
  const book = useLoanBook();
  const refetch = book.refetch;
  const reread = useCallback(() => {
    void refetch();
  }, [refetch]);

  const rows = useMemo(() => {
    const all = book.data?.rows ?? [];
    if (!onlySubject || !subject) return all;
    return all.filter((r) => r.borrower.toLowerCase() === subject.toLowerCase());
  }, [book.data, onlySubject, subject]);

  const tally = useMemo(() => {
    const all = book.data?.rows ?? [];
    return {
      active: all.filter((r) => r.status === 1).length,
      repaid: all.filter((r) => r.status === 2).length,
      defaulted: all.filter((r) => r.status === 3).length,
      defaultable: all.filter((r) => r.defaultable).length,
      principal: all.reduce((a, r) => (r.status === 1 ? a + r.principal : a), 0n),
    };
  }, [book.data]);

  return (
    <div className="space-y-4">
      <ScreenHead
        title="Loan Book"
        blurb="Every position the protocol has ever written, iterated straight from the contract. A matured, unpaid loan can be written off by anyone once the grace period lapses — recognising a bad debt should not depend on an operator choosing to recognise it."
      />

      <Panel
        label="Book"
        sub="loanCount() → loan(id) for every id"
        bodyClass="p-0"
        right={
          <div className="flex items-center gap-2">
            {subject ? (
              <button
                className={`btn !px-2.5 !py-1 ${onlySubject ? "btn-key" : ""}`}
                onClick={() => setOnlySubject((v) => !v)}
              >
                Subject only
              </button>
            ) : null}
            <button
              className="btn !px-2.5 !py-1"
              onClick={() => void book.refetch()}
              disabled={book.isFetching}
            >
              {book.isFetching ? "Reading…" : "Refresh"}
            </button>
          </div>
        }
      >
        {/* ---- tally --------------------------------------------------- */}
        <div className="grid grid-cols-2 border-b border-[var(--color-line)] sm:grid-cols-3 lg:grid-cols-5">
          <Cell label="Loans written">
            <span className="num text-[1.0625rem]">{book.data?.count ?? "···"}</span>
          </Cell>
          <Cell label="Active">
            <span className="num text-[1.0625rem]">{book.data ? tally.active : "···"}</span>
          </Cell>
          <Cell label="Repaid">
            <span className="num text-[1.0625rem] text-[var(--color-teal)]">
              {book.data ? tally.repaid : "···"}
            </span>
          </Cell>
          <Cell label="Written off">
            <span
              className={`num text-[1.0625rem] ${
                tally.defaulted > 0 ? "text-[var(--color-refuse)]" : "text-[var(--color-bone-ghost)]"
              }`}
            >
              {book.data ? tally.defaulted : "···"}
            </span>
          </Cell>
          <Cell label="Principal active">
            {book.data ? (
              <Amount value={tally.principal} size="md" tone={tally.principal ? "normal" : "dim"} />
            ) : (
              <span className="num text-[var(--color-bone-ghost)]">···</span>
            )}
          </Cell>
        </div>

        {book.error ? (
          <div className="p-4">
            <Fault error={book.error} what="CreditManager.loanCount / loan" />
          </div>
        ) : !book.data ? (
          <div className="p-4">
            <Empty>Reading the book</Empty>
          </div>
        ) : book.data.count === 0 ? (
          <div className="p-4">
            <div className="border border-dashed border-[var(--color-line-lift)] px-5 py-10 text-center">
              <div className="num text-[0.875rem] text-[var(--color-bone-dim)]">
                loanCount() → 0
              </div>
              <p className="mx-auto mt-3 max-w-[56ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-faint)]">
                No loan has been written yet. This is the real value read from the deployed
                contract — nothing is being invented to fill the table.
              </p>
            </div>
          </div>
        ) : rows.length === 0 ? (
          <div className="p-4">
            <Empty>No loans for this subject</Empty>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[68rem] border-collapse">
              <thead>
                <tr className="border-b border-[var(--color-line)] bg-[var(--color-panel-sunk)]">
                  <Th className="w-16">ID</Th>
                  <Th className="w-24">Status</Th>
                  <Th className="w-44">Borrower</Th>
                  <Th align="right">Principal</Th>
                  <Th align="right">Collateral</Th>
                  <Th align="right">Interest</Th>
                  <Th align="right" className="w-20">
                    APR
                  </Th>
                  <Th className="w-48">Due</Th>
                  <Th className="w-40">Write-off</Th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <BookRow key={row.id} row={row} onDone={reread} />
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="border-t border-[var(--color-line)] p-4">
          <Note>
            <span className="num">markDefault(id)</span> is permissionless — anyone may call it once
            a loan is {GRACE_PERIOD_SECONDS / 86_400} days past maturity. The collateral is recovered
            to the pool, the shortfall is booked against the share price, and the write-off is
            recorded against the borrower&apos;s identity, where it follows them to every wallet they
            ever open.
          </Note>
        </div>
      </Panel>
    </div>
  );
}

function BookRow({ row, onDone }: { row: LoanRow; onDone: () => void }) {
  const { contracts, chainId, txUrl } = useNetwork();
  const mark = useWriteContract();
  const rc = useWaitForTransactionReceipt({
    chainId,
    hash: mark.data,
    query: { enabled: Boolean(mark.data) },
  });

  // A confirmed write-off changes the whole book, so re-read it once the receipt lands.
  useEffect(() => {
    if (rc.isSuccess) onDone();
  }, [rc.isSuccess, onDone]);

  const status = LOAN_STATUS[row.status] ?? "Unknown";
  const tone = row.status === 3 ? "deny" : row.status === 2 ? "pass" : "idle";
  const overdue = row.status === 1 && Number(row.dueAt) * 1000 < Date.now();

  return (
    <tr className="border-b border-[var(--color-line)] hover:bg-[var(--color-panel-lift)]">
      <Td>
        <span className="num text-[0.8125rem]">#{row.id}</span>
      </Td>
      <Td>
        <Tag tone={tone}>{status}</Tag>
      </Td>
      <Td>
        <div className="flex flex-col gap-1">
          <Addr address={row.borrower} head={8} tail={6} />
          <Hash value={row.kycHash} head={8} tail={6} />
        </div>
      </Td>
      <Td align="right">
        <Amount value={row.principal} size="sm" unit={null} />
      </Td>
      <Td align="right">
        <Amount value={row.collateral} size="sm" unit={null} tone="dim" />
      </Td>
      <Td align="right">
        <Amount value={row.interestDue} size="sm" unit={null} tone="dim" />
      </Td>
      <Td align="right">
        <span className="num text-[0.75rem]">{bpsToPercent(row.aprBps)}</span>
      </Td>
      <Td>
        <div className="flex flex-col gap-0.5">
          <span className={`num text-[0.6875rem] ${overdue ? "text-[var(--color-refuse)]" : ""}`}>
            {formatTimestamp(row.dueAt)}
          </span>
          <span className="lbl-micro !tracking-[0.1em]">{relativeTime(row.dueAt)}</span>
        </div>
      </Td>
      <Td>
        {row.status !== 1 ? (
          <span className="lbl-micro">closed</span>
        ) : row.defaultable ? (
          <div className="space-y-1">
            <button
              className="btn btn-refuse !px-2.5 !py-1"
              disabled={mark.isPending || rc.isLoading}
              onClick={() =>
                mark.writeContract({
                  chainId,
                  address: contracts.creditManager,
                  abi: creditManagerAbi,
                  functionName: "markDefault",
                  args: [BigInt(row.id)],
                })
              }
            >
              {mark.isPending || rc.isLoading ? "Writing off…" : "markDefault"}
            </button>
            <div className="lbl-micro !text-[var(--color-refuse)]">permissionless</div>
            {mark.error ? (
              <div
                className="num max-w-[10rem] truncate text-[0.625rem] text-[var(--color-refuse)]"
                title={shortError(mark.error)}
              >
                {shortError(mark.error)}
              </div>
            ) : null}
            {mark.data ? (
              <a
                href={txUrl(mark.data)}
                target="_blank"
                rel="noreferrer"
                className="num text-[0.625rem] text-[var(--color-teal)]"
              >
                {rc.isLoading ? "pending" : "confirmed"} ↗
              </a>
            ) : null}
          </div>
        ) : (
          <div className="flex flex-col gap-0.5">
            <span className="lbl-micro">not yet defaultable</span>
            <span className="num text-[0.625rem] text-[var(--color-bone-faint)]">
              {relativeTime(Number(row.dueAt) + GRACE_PERIOD_SECONDS)}
            </span>
          </div>
        )}
      </Td>
    </tr>
  );
}

function Cell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="border-r border-[var(--color-line)] p-4 last:border-r-0">
      <div className="lbl mb-2">{label}</div>
      {children}
    </div>
  );
}

function Th({
  children,
  align = "left",
  className = "",
}: {
  children?: React.ReactNode;
  align?: "left" | "right";
  className?: string;
}) {
  return (
    <th
      scope="col"
      className={`lbl px-3 py-2 ${align === "right" ? "text-right" : "text-left"} ${className}`}
    >
      {children}
    </th>
  );
}

function Td({
  children,
  align = "left",
}: {
  children?: React.ReactNode;
  align?: "left" | "right";
}) {
  return (
    <td className={`px-3 py-2.5 align-top ${align === "right" ? "text-right" : "text-left"}`}>
      {children}
    </td>
  );
}
