"use client";

import { useState } from "react";
import { useSubject } from "@/lib/subject";
import {
  useAssetBalance,
  useCredential,
  useHistory,
  useMaxLoanPrincipal,
  useMaxTermSeconds,
  useMinLoanPrincipal,
  usePoolScalar,
  useQuote,
} from "@/lib/reads";
import { parseUnits6 } from "@/lib/format";
import { ZERO_HASH } from "@/lib/contracts";
import { CredentialPanel } from "@/components/borrower/CredentialPanel";
import { StandingPanel } from "@/components/borrower/StandingPanel";
import { OfferPanel } from "@/components/borrower/OfferPanel";
import { HistoryPanel } from "@/components/borrower/HistoryPanel";
import { CeilingsPanel } from "@/components/borrower/CeilingsPanel";
import { AwaitSubject } from "@/components/AwaitSubject";
import { ScreenHead } from "@/components/ScreenHead";

export default function BorrowerScreen() {
  const { subject } = useSubject();
  const [amountInput, setAmountInput] = useState("1000");
  const [termDays, setTermDays] = useState(30);

  const amount = parseUnits6(amountInput) ?? 0n;
  const termSeconds = BigInt(Math.max(0, termDays) * 86_400);

  const credential = useCredential(subject);
  const balance = useAssetBalance(subject);
  const kycHash =
    credential.data?.kycHash && credential.data.kycHash !== ZERO_HASH
      ? credential.data.kycHash
      : undefined;
  const history = useHistory(kycHash);
  const quote = useQuote(subject, amount, termSeconds);

  const minLoanPrincipal = useMinLoanPrincipal();
  const maxLoanPrincipal = useMaxLoanPrincipal();
  const maxTermSeconds = useMaxTermSeconds();
  const availableLiquidity = usePoolScalar("availableLiquidity");

  return (
    <div className="space-y-4">
      <ScreenHead
        title="Borrower"
        blurb="One credential, one score, one set of terms — each read live from the deployed contracts. The credential is the collateral; the numbers below are the ones the contract will enforce."
      />

      {!subject ? (
        <AwaitSubject what="a borrower" />
      ) : (
        <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,25rem)]">
          <div className="min-w-0 space-y-4">
            <StandingPanel
              quote={quote}
              credential={credential.data}
              history={history.data}
              balance={balance.data}
            />
            <OfferPanel
              subject={subject}
              quote={quote}
              amount={amount}
              amountInput={amountInput}
              setAmountInput={setAmountInput}
              termDays={termDays}
              setTermDays={setTermDays}
              minLoanPrincipal={minLoanPrincipal.data}
              maxLoanPrincipal={maxLoanPrincipal.data}
              maxTermSeconds={maxTermSeconds.data}
              availableLiquidity={availableLiquidity.data}
            />
          </div>
          <div className="min-w-0 space-y-4">
            <CredentialPanel subject={subject} />
            <HistoryPanel kycHash={kycHash} />
            <CeilingsPanel />
          </div>
        </div>
      )}
    </div>
  );
}
