import type { Address, Hex } from "viem";

/** ApassReader.Credential, as returned by CreditManager.credentialOf. */
export type Credential = {
  exists: boolean;
  status: number;
  tier: number;
  subTier: number;
  group: Hex;
  subGroup: Hex;
  expiresAt: bigint;
  issuedAt: bigint;
  kycHash: Hex;
  previousKycHash: Hex;
};

/** StandingMath.Breakdown. */
export type Breakdown = {
  tierPoints: bigint;
  subTierPoints: bigint;
  tenurePoints: bigint;
  repaymentPoints: bigint;
  volumePoints: bigint;
  defaultPenalty: bigint;
  assetPoints: bigint;
  identitySubtotal: bigint;
  historySubtotal: bigint;
  assetSubtotal: bigint;
  score: bigint;
};

/** CreditManager.Quote. */
export type Quote = {
  approved: boolean;
  refusal: number;
  score: bigint;
  creditLine: bigint;
  alreadyDrawn: bigint;
  maxDrawNow: bigint;
  collateralRequired: bigint;
  aprBps: bigint;
  interestForTerm: bigint;
  breakdown: Breakdown;
};

/** StandingRegistry.History. */
export type History = {
  loansOriginated: number;
  loansRepaid: number;
  loansDefaulted: number;
  totalBorrowed: bigint;
  totalRepaid: bigint;
  totalDefaulted: bigint;
  firstSeenAt: bigint;
  lastActivityAt: bigint;
};

/** CreditManager.Loan. */
export type Loan = {
  borrower: Address;
  kycHash: Hex;
  principal: bigint;
  collateral: bigint;
  interestDue: bigint;
  openedAt: bigint;
  dueAt: bigint;
  aprBps: number;
  status: number;
};

export type LoanRow = Loan & { id: number; defaultable: boolean };

/** The shape every read in the console is rendered through. */
export type ReadState<T> = {
  data: T | undefined;
  error: unknown;
  isPending: boolean;
};
