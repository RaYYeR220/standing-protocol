import type { Breakdown, Credential, History, Quote, Terms } from "./types.js";

const UNIT = 1_000_000n;

export function amount(v: bigint): string {
  const whole = v / UNIT;
  const frac = (v % UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  return frac ? `${whole.toLocaleString("en-US")}.${frac}` : whole.toLocaleString("en-US");
}

export function pct(bps: bigint | number): string {
  return `${(Number(bps) / 100).toFixed(2)}%`;
}

const REFUSALS: Record<number, string> = {
  0: "no refusal",
  1: "the party holds no Cleanverse A-Pass",
  2: "the party's A-Pass is frozen",
  3: "the party's A-Pass has expired",
  4: "Cleanverse's policy engine refused the transfer under the asset's own rules",
  5: "Cleanverse's policy engine refused the transfer under this protocol's rule set",
};

export function refusal(code: number): string {
  return REFUSALS[code] ?? `unknown refusal code ${code}`;
}

/**
 * Renders the underwriting decision in prose.
 *
 * Every sentence below is a restatement of a number the contract already computed and enforced.
 * Nothing is inferred, estimated or generated: the explanation and the decision come from the same
 * arithmetic, so an operator reading this is reading the contract's reasoning rather than a
 * plausible account of it.
 */
export function explainQuote(q: Quote, c: Credential): string[] {
  const out: string[] = [];
  const b: Breakdown = q.breakdown;

  if (!c.exists) {
    out.push("This wallet holds no Cleanverse A-Pass, so it has no standing and cannot borrow.");
    out.push("Identity is the collateral here; without a credential there is nothing to lend against.");
    return out;
  }
  if (c.status !== 1) {
    out.push(`The credential is frozen (status ${c.status}). Every path that moves value is closed.`);
    return out;
  }

  out.push(
    `Score ${b.score} of 1000, from three components: identity ${b.identitySubtotal}, ` +
      `credit history ${b.historySubtotal}, verified assets ${b.assetSubtotal}.`
  );
  out.push(
    `Identity: verification tier ${c.tier} contributes ${b.tierPoints}, sub-tier ${c.subTier} ` +
      `contributes ${b.subTierPoints}, and the credential's age contributes ${b.tenurePoints}.`
  );

  if (b.repaymentPoints === 0n && b.defaultPenalty === 0n) {
    out.push("Credit history: none yet with this protocol. The first loan is priced on identity alone.");
  } else {
    out.push(
      `Credit history: ${b.repaymentPoints} points from qualifying repayments and ` +
        `${b.volumePoints} from repaid volume` +
        (b.defaultPenalty > 0n
          ? `, less a ${b.defaultPenalty}-point penalty for defaults. A write-off is deducted from ` +
            `the whole score, not just this component, so it cannot be offset by a large balance.`
          : ".")
    );
  }

  out.push(`Verified assets: ${b.assetPoints} points. Only Cleanverse-verified holdings count.`);

  if (!q.approved) {
    out.push(
      q.refusal !== 0
        ? `Refused: ${refusal(q.refusal)}.`
        : q.score < 350n
          ? `Refused: score ${b.score} is below the protocol minimum of 350.`
          : `Refused: the request is outside what this standing supports right now ` +
            `(maximum draw ${amount(q.maxDrawNow)} aUSDC).`
    );
    return out;
  }

  out.push(
    `Approved. Credit line ${amount(q.creditLine)} aUSDC, of which ${amount(q.alreadyDrawn)} is ` +
      `already drawn; up to ${amount(q.maxDrawNow)} is available now.`
  );
  out.push(
    `Collateral required ${amount(q.collateralRequired)} aUSDC at ${pct(q.aprBps)} APR — ` +
      `less than the principal, which is the whole point: the shortfall is covered by standing, ` +
      `not by assets.`
  );
  out.push(
    "The credit line is held against the identity behind the credential, not this wallet. " +
      "A second wallet under the same identity draws on the same line."
  );
  return out;
}

export function explainCredential(c: Credential, h: History, wallets: readonly string[]): string[] {
  if (!c.exists) return ["No Cleanverse A-Pass is bound to this address."];
  const out = [
    `A-Pass: tier ${c.tier}, sub-tier ${c.subTier}, status ${c.status === 1 ? "active" : c.status === 2 ? "frozen" : "uninitialised"}.`,
    `Issued ${new Date(Number(c.issuedAt) * 1000).toISOString().slice(0, 10)}, ` +
      `expires ${new Date(Number(c.expiresAt) * 1000).toISOString().slice(0, 10)}.`,
    `Identity anchor (KYC hash): ${c.kycHash}`,
  ];
  if (c.previousKycHash !== `0x${"0".repeat(64)}`) {
    out.push(
      `This credential supersedes ${c.previousKycHash}. The protocol unions the two, so the ` +
        `history below survived the re-verification.`
    );
  }
  out.push(
    `History with this protocol: ${h.loansOriginated} originated, ${h.loansRepaid} repaid, ` +
      `${h.loansDefaulted} defaulted; ${amount(h.totalBorrowed)} borrowed and ` +
      `${amount(h.totalRepaid)} returned in aUSDC.`
  );
  if (wallets.length > 1) {
    out.push(`Wallets seen acting under this identity: ${wallets.join(", ")}.`);
  }
  return out;
}

export function explainTerms(t: Terms): string {
  if (!t.eligible) return "Below the minimum standing; no terms are offered at any collateral level.";
  return `Line ${amount(t.creditLine)} aUSDC · collateral ${pct(t.collateralBps)} of principal · ${pct(t.aprBps)} APR.`;
}
