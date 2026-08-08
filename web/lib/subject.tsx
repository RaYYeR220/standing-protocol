"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { getAddress, type Address } from "viem";
import { useAccount } from "wagmi";
import { isAddressish } from "./format";

type SubjectCtx = {
  /** Raw text in the subject field — may be mid-typing and invalid. */
  raw: string;
  /** Checksummed address, or undefined when the field does not hold one. */
  subject: Address | undefined;
  setRaw: (v: string) => void;
  /** True when the subject tracks the connected wallet rather than a typed address. */
  pinnedToWallet: boolean;
  followWallet: () => void;
};

const Ctx = createContext<SubjectCtx | null>(null);

/**
 * The address under examination. Shared by the borrower, compliance and loan-book
 * screens, mirrored into the query string so a view can be linked to directly.
 */
export function SubjectProvider({ children }: { children: ReactNode }) {
  const { address } = useAccount();
  const [raw, setRawState] = useState("");
  const [pinnedToWallet, setPinned] = useState(true);

  // Seed from ?a= on first paint so a shared link opens on the same subject.
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("a");
    if (q && isAddressish(q)) {
      setRawState(q);
      setPinned(false);
    }
  }, []);

  useEffect(() => {
    if (pinnedToWallet && address) setRawState(address);
  }, [pinnedToWallet, address]);

  const subject = useMemo(() => {
    if (!isAddressish(raw)) return undefined;
    try {
      return getAddress(raw.trim());
    } catch {
      return undefined;
    }
  }, [raw]);

  useEffect(() => {
    const url = new URL(window.location.href);
    if (subject) url.searchParams.set("a", subject);
    else url.searchParams.delete("a");
    window.history.replaceState(null, "", url);
  }, [subject]);

  const setRaw = useCallback((v: string) => {
    setRawState(v);
    setPinned(false);
  }, []);

  const followWallet = useCallback(() => setPinned(true), []);

  return (
    <Ctx.Provider value={{ raw, subject, setRaw, pinnedToWallet, followWallet }}>
      {children}
    </Ctx.Provider>
  );
}

export function useSubject() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useSubject must be used inside SubjectProvider");
  return v;
}
