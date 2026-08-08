"use client";

import { useReadContract } from "wagmi";
import type { Address, Hex } from "viem";
import {
  cleanversePolicyAbi,
  creditManagerAbi,
  erc20Abi,
  standingPoolAbi,
  standingRegistryAbi,
} from "./abi";
import { CONTRACTS } from "./contracts";
import type { Credential, History, Quote, ReadState } from "./types";

/** Polling cadence. The endpoint is a shared public node, so this is deliberately unhurried. */
const LIVE = 12_000;
const SLOW = 60_000;
/** Deployment-time constants never change; read once. */
const FROZEN = Infinity;

function state<T>(r: {
  data: unknown;
  error: unknown;
  isPending: boolean;
}): ReadState<T> {
  return { data: r.data as T | undefined, error: r.error, isPending: r.isPending };
}

/* ------------------------------------------------------------------ identity */

export function useCredential(party: Address | undefined): ReadState<Credential> {
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName: "credentialOf",
    args: party ? [party] : undefined,
    query: { enabled: Boolean(party), refetchInterval: LIVE },
  });
  return state<Credential>(r);
}

/** `checkParty` → [ok, refusalCode] */
export function useCheckParty(party: Address | undefined): ReadState<readonly [boolean, number]> {
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName: "checkParty",
    args: party ? [party] : undefined,
    query: { enabled: Boolean(party), refetchInterval: LIVE },
  });
  return state<readonly [boolean, number]>(r);
}

/** `checkTransferDetailed` → [allowed, refusalCode, failingParty] */
export function useCheckTransfer(
  from: Address | undefined,
  to: Address | undefined,
  amount: bigint | undefined,
): ReadState<readonly [boolean, number, Address]> {
  const ready = Boolean(from && to && amount !== undefined);
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName: "checkTransferDetailed",
    args: ready ? [from as Address, to as Address, amount as bigint] : undefined,
    query: { enabled: ready, refetchInterval: LIVE },
  });
  return state<readonly [boolean, number, Address]>(r);
}

export function useCanonicalIdentity(kycHash: Hex | undefined): ReadState<Hex> {
  const r = useReadContract({
    address: CONTRACTS.standingRegistry,
    abi: standingRegistryAbi,
    functionName: "canonicalIdentity",
    args: kycHash ? [kycHash] : undefined,
    query: { enabled: Boolean(kycHash), refetchInterval: SLOW },
  });
  return state<Hex>(r);
}

export function useHistory(kycHash: Hex | undefined): ReadState<History> {
  const r = useReadContract({
    address: CONTRACTS.standingRegistry,
    abi: standingRegistryAbi,
    functionName: "historyOf",
    args: kycHash ? [kycHash] : undefined,
    query: { enabled: Boolean(kycHash), refetchInterval: LIVE },
  });
  return state<History>(r);
}

export function useWallets(kycHash: Hex | undefined): ReadState<readonly Address[]> {
  const r = useReadContract({
    address: CONTRACTS.standingRegistry,
    abi: standingRegistryAbi,
    functionName: "walletsOf",
    args: kycHash ? [kycHash] : undefined,
    query: { enabled: Boolean(kycHash), refetchInterval: SLOW },
  });
  return state<readonly Address[]>(r);
}

export function useDrawnByIdentity(kycHash: Hex | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName: "drawnByIdentity",
    args: kycHash ? [kycHash] : undefined,
    query: { enabled: Boolean(kycHash), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

/* --------------------------------------------------------------- underwriting */

export function useQuote(
  borrower: Address | undefined,
  amount: bigint,
  termSeconds: bigint,
): ReadState<Quote> {
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName: "quote",
    args: borrower ? [borrower, amount, termSeconds] : undefined,
    query: { enabled: Boolean(borrower), refetchInterval: LIVE },
  });
  return state<Quote>(r);
}

function useManagerConstant(
  functionName: "maxLoanPrincipal" | "maxCreditLine" | "maxTermSeconds" | "MIN_LOAN_PRINCIPAL" | "MIN_TERM_SECONDS" | "GRACE_PERIOD" | "loanCount",
  interval: number,
): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.creditManager,
    abi: creditManagerAbi,
    functionName,
    query: { refetchInterval: interval === FROZEN ? false : interval, staleTime: interval === FROZEN ? Infinity : undefined },
  });
  return state<bigint>(r);
}

export const useMaxLoanPrincipal = () => useManagerConstant("maxLoanPrincipal", FROZEN);
export const useMaxCreditLine = () => useManagerConstant("maxCreditLine", FROZEN);
export const useMaxTermSeconds = () => useManagerConstant("maxTermSeconds", FROZEN);
export const useMinLoanPrincipal = () => useManagerConstant("MIN_LOAN_PRINCIPAL", FROZEN);
export const useLoanCount = () => useManagerConstant("loanCount", LIVE);

/* ----------------------------------------------------------------------- pool */

type PoolScalar =
  | "totalAssets"
  | "availableLiquidity"
  | "outstandingPrincipal"
  | "utilizationBps"
  | "lifetimeInterest"
  | "lifetimeLosses"
  | "maxUtilizationBps"
  | "totalSupply";

export function usePoolScalar(functionName: PoolScalar): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName,
    query: { refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function usePoolDecimals(): ReadState<number> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "decimals",
    query: { staleTime: Infinity },
  });
  return state<number>(r);
}

export function useConvertToAssets(shares: bigint | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "convertToAssets",
    args: shares !== undefined ? [shares] : undefined,
    query: { enabled: shares !== undefined, refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function useShareBalance(owner: Address | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: { enabled: Boolean(owner), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function useMaxWithdraw(owner: Address | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "maxWithdraw",
    args: owner ? [owner] : undefined,
    query: { enabled: Boolean(owner), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function useMaxDeposit(receiver: Address | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "maxDeposit",
    args: receiver ? [receiver] : undefined,
    query: { enabled: Boolean(receiver), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function usePreviewDeposit(assets: bigint | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.standingPool,
    abi: standingPoolAbi,
    functionName: "previewDeposit",
    args: assets !== undefined ? [assets] : undefined,
    query: { enabled: assets !== undefined && assets > 0n, refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

/* ---------------------------------------------------------------------- asset */

export function useAssetBalance(owner: Address | undefined): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.verifiedAsset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: { enabled: Boolean(owner), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

export function useAllowance(
  owner: Address | undefined,
  spender: Address,
): ReadState<bigint> {
  const r = useReadContract({
    address: CONTRACTS.verifiedAsset,
    abi: erc20Abi,
    functionName: "allowance",
    args: owner ? [owner, spender] : undefined,
    query: { enabled: Boolean(owner), refetchInterval: LIVE },
  });
  return state<bigint>(r);
}

/* --------------------------------------------------------------------- policy */

export function useIsTokenRegistered(subject: Address): ReadState<boolean> {
  const r = useReadContract({
    address: CONTRACTS.policy,
    abi: cleanversePolicyAbi,
    functionName: "isTokenRegistered",
    args: [subject],
    query: { refetchInterval: SLOW },
  });
  return state<boolean>(r);
}
