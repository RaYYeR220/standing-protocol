export type Hex = `0x${string}`;

export interface Credential {
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
}

export interface Breakdown {
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
}

export interface Quote {
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
}

export interface Terms {
  eligible: boolean;
  creditLine: bigint;
  collateralBps: bigint;
  aprBps: bigint;
}

export interface History {
  loansOriginated: number;
  loansRepaid: number;
  loansDefaulted: number;
  totalBorrowed: bigint;
  totalRepaid: bigint;
  totalDefaulted: bigint;
  firstSeenAt: bigint;
  lastActivityAt: bigint;
}

export interface Loan {
  borrower: Hex;
  kycHash: Hex;
  principal: bigint;
  collateral: bigint;
  interestDue: bigint;
  openedAt: bigint;
  dueAt: bigint;
  aprBps: number;
  status: number;
}

export const LOAN_STATUS = ["none", "active", "repaid", "defaulted"] as const;
