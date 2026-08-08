"use client";

import type { Address, Hex } from "viem";
import { Addr, Amount, Empty, Fault, Note, Panel, Row, Stamp, Tag } from "../primitives";
import { MIN_QUALIFYING_HOLD, SCORING } from "@/lib/contracts";
import { useHistory, useWalletDefaults, useWallets } from "@/lib/reads";

/**
 * The registry record. Keyed to the identity behind the credential rather than to
 * the wallet, which is the whole reason a default is worth anything as security.
 */
export function HistoryPanel({
  kycHash,
  subject,
}: {
  kycHash: Hex | undefined;
  subject: Address | undefined;
}) {
  const history = useHistory(kycHash);
  const wallets = useWallets(kycHash);
  const walletDefaults = useWalletDefaults(subject);

  if (!kycHash) {
    return (
      <Panel label="Record" sub="StandingRegistry.historyOf(identity)">
        <Empty>No identity — no record to keep</Empty>
        <Note>
          History is written against the A-Pass KYC hash. Without a credential there is nothing to
          write it against, which is precisely why an uncredentialed wallet cannot borrow.
        </Note>
      </Panel>
    );
  }

  if (history.error) {
    return (
      <Panel label="Record" sub="StandingRegistry.historyOf(identity)">
        <Fault error={history.error} what="StandingRegistry.historyOf" />
      </Panel>
    );
  }

  const h = history.data;
  const virgin = h && h.loansOriginated === 0 && h.loansDefaulted === 0;

  return (
    <Panel
      label="Record"
      sub="keyed to the identity, not the wallet"
      right={
        h ? (
          h.loansDefaulted > 0 ? (
            <Tag tone="deny">{h.loansDefaulted} WRITE-OFF</Tag>
          ) : virgin ? (
            <Tag tone="idle">NO HISTORY</Tag>
          ) : (
            <Tag tone="pass">CLEAN</Tag>
          )
        ) : (
          <Tag tone="idle">READING</Tag>
        )
      }
      bodyClass="p-0"
    >
      {!h ? (
        <div className="p-4">
          <Empty>Reading registry</Empty>
        </div>
      ) : (
        <>
          <div className="px-4 py-1">
            <Row label="Loans originated">
              <span className="num text-[1.0625rem]">{h.loansOriginated}</span>
            </Row>
            <Row label="Repaid" note={`only loans held ≥ ${MIN_QUALIFYING_HOLD / 3600}h count`}>
              <span className="num text-[1.0625rem] text-[var(--color-teal)]">{h.loansRepaid}</span>
            </Row>
            <Row label="Written off">
              <span
                className={`num text-[1.0625rem] ${
                  h.loansDefaulted > 0
                    ? "text-[var(--color-refuse)]"
                    : "text-[var(--color-bone-ghost)]"
                }`}
              >
                {h.loansDefaulted}
              </span>
            </Row>
            <Row label="Borrowed lifetime">
              <Amount value={h.totalBorrowed} size="sm" />
            </Row>
            <Row label="Returned lifetime" note="qualifying principal plus interest">
              <Amount value={h.totalRepaid} size="sm" />
            </Row>
            <Row label="Defaulted lifetime">
              <Amount
                value={h.totalDefaulted}
                size="sm"
                tone={h.totalDefaulted > 0n ? "refuse" : "dim"}
              />
            </Row>
            <Row label="First seen">
              {h.firstSeenAt > 0n ? (
                <Stamp seconds={h.firstSeenAt} />
              ) : (
                <span className="num text-[var(--color-bone-ghost)]">never</span>
              )}
            </Row>
            <Row label="Last activity">
              {h.lastActivityAt > 0n ? (
                <Stamp seconds={h.lastActivityAt} />
              ) : (
                <span className="num text-[var(--color-bone-ghost)]">never</span>
              )}
            </Row>
          </div>

          <div className="border-t border-[var(--color-line)] px-4 py-1">
            <Row
              label="Write-offs against this wallet"
              note="StandingRegistry.walletDefaults(wallet)"
            >
              {walletDefaults.error ? (
                <Tag tone="deny">RPC FAULT</Tag>
              ) : walletDefaults.data === undefined ? (
                <span className="num text-[var(--color-bone-ghost)] sp-pulse">······</span>
              ) : (
                <span
                  className={`num text-[1.0625rem] ${
                    walletDefaults.data > 0
                      ? "text-[var(--color-refuse)]"
                      : "text-[var(--color-bone-ghost)]"
                  }`}
                >
                  {walletDefaults.data}
                </span>
              )}
            </Row>
            <div className="py-2.5">
              <Note>
                A write-off is recorded twice — once against the identity above and once against the
                wallet that drew the loan. The score subtracts{" "}
                <span className="num">
                  max(identity, wallet) × {SCORING.DEFAULT_PENALTY}
                </span>
                , never the sum, so it is paid for once and cannot be escaped by leaving either
                record behind. Re-verifying under a fresh KYC hash does not clear it: the wallet
                still carries its own count.
              </Note>
            </div>
          </div>

          <div className="border-t border-[var(--color-line)] p-4">
            <div className="lbl mb-2.5">
              Wallets under this identity
              {wallets.data ? ` · ${wallets.data.length}` : ""}
            </div>
            {wallets.error ? (
              <Tag tone="deny">RPC FAULT</Tag>
            ) : !wallets.data || wallets.data.length === 0 ? (
              <span className="lbl-micro">none recorded</span>
            ) : (
              <ul className="space-y-1.5">
                {wallets.data.map((w) => (
                  <li key={w}>
                    <Addr address={w} head={12} tail={8} tone="dim" />
                  </li>
                ))}
              </ul>
            )}
            <Note>
              A borrower who opens a second wallet does not get a second credit line. The KYC hash is
              the same, so the line is the same one — already partly drawn.
            </Note>
          </div>
        </>
      )}
    </Panel>
  );
}
