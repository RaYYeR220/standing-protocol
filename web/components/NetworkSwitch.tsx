"use client";

import { NETWORK_KEYS, NETWORKS } from "@/lib/chain";
import { useNetwork } from "@/lib/network";

/**
 * The deployment selector. Switching swaps RPC, explorer and address set as one
 * unit — no screen ever shows a reading from one chain beside an address from the
 * other. The choice is carried in the query string, so a link keeps it.
 */
export function NetworkSwitch() {
  const { key, setNetwork } = useNetwork();
  return (
    <div className="flex items-center" role="group" aria-label="Deployment">
      {NETWORK_KEYS.map((k, i) => {
        const net = NETWORKS[k];
        const active = k === key;
        return (
          <button
            key={k}
            className={`btn !px-2.5 !py-1 ${active ? "btn-key" : ""} ${i > 0 ? "-ml-px" : ""}`}
            aria-pressed={active}
            title={`${net.chain.name} · chain ${net.chain.id}`}
            onClick={() => setNetwork(k)}
          >
            {net.short}
          </button>
        );
      })}
    </div>
  );
}
