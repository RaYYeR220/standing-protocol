"use client";
import { usePathname } from "next/navigation";
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  DEFAULT_NETWORK,
  explorerAddress,
  explorerTx,
  isNetworkKey,
  NETWORKS,
  type ChainId,
  type ContractSet,
  type Deployment,
  type NetworkKey,
} from "./chain";

type NetworkCtx = {
  key: NetworkKey;
  deployment: Deployment;
  /** The address set of the selected deployment. Never mixed across chains. */
  contracts: ContractSet;
  chainId: ChainId;
  setNetwork: (k: NetworkKey) => void;
  addressUrl: (address: string) => string;
  txUrl: (hash: string) => string;
};

const Ctx = createContext<NetworkCtx | null>(null);

/**
 * Which deployment the terminal is pointed at. RPC, explorer and address set move
 * together, so a screen can never render a Base address against a Monad reading.
 * Mirrored into the query string as `?n=` beside the subject's `?a=`.
 */
export function NetworkProvider({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const [key, setKey] = useState<NetworkKey>(DEFAULT_NETWORK);
  const [seeded, setSeeded] = useState(false);

  // Seed from ?n= on first paint so a shared link opens on the same chain.
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("n");
    if (isNetworkKey(q)) setKey(q);
    setSeeded(true);
  }, []);

  // Mirror the selection back — but not before the seed has been read, or a shared
  // link would overwrite its own parameter with the default. Re-run on navigation
  // too: a tab is a bare href, so the parameter has to be put back after the push.
  useEffect(() => {
    if (!seeded) return;
    const url = new URL(window.location.href);
    url.searchParams.set("n", key);
    window.history.replaceState(null, "", url);
  }, [key, seeded, pathname]);

  const value = useMemo<NetworkCtx>(() => {
    const deployment = NETWORKS[key];
    return {
      key,
      deployment,
      contracts: deployment.contracts,
      chainId: deployment.chain.id,
      setNetwork: setKey,
      addressUrl: (address: string) => explorerAddress(deployment.explorer, address),
      txUrl: (hash: string) => explorerTx(deployment.explorer, hash),
    };
  }, [key]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useNetwork() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useNetwork must be used inside NetworkProvider");
  return v;
}
