import type { Address } from "viem";

/** Deployed on Monad testnet (chainId 10143). Mirrors contracts/deployments/monad-testnet.json. */
export const CONTRACTS = {
  creditManager: "0x324719787E22a7c2c3E77bc84484317c2D2D1093",
  standingPool: "0x5ae228215dae30EC07D0196B13179CFA00146D03",
  standingRegistry: "0xE066669d09afd30444429003987b9E7BcA970F19",
  apassRegistry: "0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9",
  policy: "0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd",
  verifiedAsset: "0xaC0893567D43C3E7e6e35a72803df05416C1f20D",
} as const satisfies Record<string, Address>;

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;
export const ZERO_HASH = `0x${"0".repeat(64)}` as const;

/** aUSDC — a Cleanverse Verified Asset. Six decimals. */
export const ASSET_DECIMALS = 6;
export const ASSET_SYMBOL = "aUSDC";
export const SHARE_SYMBOL = "stdaUSDC";

/** Mirrors ComplianceGate.Refusal. */
export const REFUSAL = [
  "None",
  "NoCredential",
  "CredentialFrozen",
  "CredentialExpired",
  "AssetPolicyDenied",
  "ProtocolPolicyDenied",
] as const;

export type RefusalName = (typeof REFUSAL)[number];

export function refusalName(code: number | undefined): RefusalName {
  return REFUSAL[code ?? 0] ?? "None";
}

/** The sentence a reader gets under the enum. */
export const REFUSAL_PROSE: Record<RefusalName, string> = {
  None: "All conditions held at this block. Value may move.",
  NoCredential:
    "This party holds no Cleanverse A-Pass. There is no verified identity behind the address, so there is nothing to lend against and nobody to pursue.",
  CredentialFrozen:
    "An A-Pass exists but its status is not active. The issuing institution has frozen the credential, and a frozen credential can neither receive nor send value here.",
  CredentialExpired:
    "The A-Pass exists and is active, but its expiry has already passed at this block. Verification is a perishable claim; the gate re-reads it on every movement rather than trusting a check made once.",
  AssetPolicyDenied:
    "Cleanverse's policy engine refused this transfer under the rule set attached to aUSDC. The asset carries its compliance rules with it, and they are evaluated against both counterparties on-chain, inside the transaction.",
  ProtocolPolicyDenied:
    "Standing Protocol is registered as a policy subject at Cleanverse and its own rule set refused this transfer. An operator can tighten who may borrow or lend by changing a rule off-chain, and the contracts obey without being redeployed.",
};

/** Mirrors CreditManager.Status. */
export const LOAN_STATUS = ["None", "Active", "Repaid", "Defaulted"] as const;
export type LoanStatusName = (typeof LOAN_STATUS)[number];

/** Mirrors ApassReader status codes. */
export const APASS_STATUS: Record<number, string> = {
  0: "Uninitialized",
  1: "Active",
  2: "Frozen",
};

/** StandingMath constants, so each component can be shown against its ceiling. */
export const SCORING = {
  MAX_SCORE: 1000,
  MIN_SCORE: 400,
  IDENTITY_MAX: 400,
  HISTORY_MAX: 350,
  ASSETS_MAX: 250,
  TIER_MAX: 300,
  SUBTIER_MAX: 50,
  TENURE_MAX: 50,
  TENURE_FULL_CREDIT: 365 * 24 * 60 * 60,
  REPAID_POINTS: 25,
  REPAID_CAP: 10,
  VOLUME_POINTS: 10,
  VOLUME_CAP: 10,
  DEFAULT_PENALTY: 250,
  MAX_COLLATERAL_BPS: 8000,
  MIN_APR_BPS: 500,
  MAX_APR_BPS: 2500,
} as const;

/** The base-10 ladder in StandingMath._assetPoints, for showing the next rung. */
export const ASSET_LADDER: { threshold: bigint; points: number }[] = [
  { threshold: 1_000_000n, points: 20 },
  { threshold: 10_000_000n, points: 50 },
  { threshold: 100_000_000n, points: 100 },
  { threshold: 1_000_000_000n, points: 150 },
  { threshold: 10_000_000_000n, points: 200 },
  { threshold: 100_000_000_000n, points: 250 },
];

/** CreditManager.GRACE_PERIOD */
export const GRACE_PERIOD_SECONDS = 3 * 24 * 60 * 60;
/** CreditManager.MIN_TERM_SECONDS */
export const MIN_TERM_SECONDS = 24 * 60 * 60;
/** StandingRegistry.MIN_QUALIFYING_HOLD */
export const MIN_QUALIFYING_HOLD = 24 * 60 * 60;

/**
 * Addresses whose live on-chain state is worth putting in front of a reader.
 * Addresses only — every attribute rendered beside them is read from chain.
 */
export const REFERENCE_WALLETS: { address: Address; label: string }[] = [
  { address: "0xBBe8DB07Eaf9C4Ac1AAA46e4197AD22AA7041F3F", label: "WALLET A" },
  { address: "0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98", label: "WALLET B" },
  { address: "0x68dC37636DA76a24eDFb0e1B308123Eb4cd50EAA", label: "WALLET C" },
];
