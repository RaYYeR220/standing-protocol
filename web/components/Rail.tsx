"use client";

import { useEffect, useState } from "react";
import { useAccount, useBlockNumber, useConnect, useDisconnect } from "wagmi";
import { Mark } from "./Mark";
import { Addr } from "./primitives";
import { monadTestnet } from "@/lib/chain";

/** The rail carries proof the console is live: chain id, height, and who is signing. */
export function Rail() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { data: block, error: blockError } = useBlockNumber({
    watch: { poll: true, pollingInterval: 4_000 },
  });

  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const injectedConnector = connectors.find((c) => c.id === "injected") ?? connectors[0];
  const wrongChain = mounted && isConnected && chainId !== monadTestnet.id;

  return (
    <header className="sticky top-0 z-30 border-b border-[var(--color-line)] bg-[var(--color-ink-deep)]/95 backdrop-blur-sm">
      <div className="mx-auto flex w-full max-w-[1680px] items-stretch gap-4 px-4 lg:px-6">
        {/* identity */}
        <div className="flex items-center gap-3 py-3 pr-5">
          <Mark size={20} />
          <div className="leading-none">
            <div className="hdg text-[0.9375rem] tracking-[-0.03em]">Standing Protocol</div>
            <div className="lbl-micro mt-1">Underwriting Terminal</div>
          </div>
        </div>

        {/* telemetry */}
        <div className="hidden flex-1 items-center gap-6 border-l border-[var(--color-line)] pl-5 md:flex">
          <Telemetry label="Network">
            <span className="num text-[0.75rem]">MONAD TESTNET</span>
          </Telemetry>
          <Telemetry label="Chain">
            <span className="num text-[0.75rem]">{monadTestnet.id}</span>
          </Telemetry>
          <Telemetry label="Block">
            {blockError ? (
              <span className="chip chip-deny">RPC FAULT</span>
            ) : block ? (
              <span className="flex items-center gap-1.5">
                <span
                  className="sp-pulse inline-block h-1.5 w-1.5 shrink-0 bg-[var(--color-teal)]"
                  aria-hidden
                />
                <span className="num text-[0.75rem] text-[var(--color-teal)]">
                  {block.toString()}
                </span>
              </span>
            ) : (
              <span className="num text-[0.75rem] text-[var(--color-bone-ghost)]">······</span>
            )}
          </Telemetry>
        </div>

        {/* signer */}
        <div className="flex items-center gap-3 border-l border-[var(--color-line)] py-2 pl-5">
          {wrongChain ? (
            <span className="chip chip-deny">WRONG CHAIN</span>
          ) : null}
          {mounted && isConnected && address ? (
            <>
              <div className="hidden text-right leading-none sm:block">
                <div className="lbl-micro mb-1">Signer</div>
                <Addr address={address} link={false} head={6} tail={4} tone="teal" />
              </div>
              <button className="btn" onClick={() => disconnect()}>
                Disconnect
              </button>
            </>
          ) : (
            <button
              className="btn btn-key"
              disabled={!mounted || isPending || !injectedConnector}
              onClick={() => injectedConnector && connect({ connector: injectedConnector })}
            >
              {isPending ? "Connecting…" : "Connect Wallet"}
            </button>
          )}
        </div>
      </div>
    </header>
  );
}

function Telemetry({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="leading-none">
      <div className="lbl-micro mb-1.5">{label}</div>
      {children}
    </div>
  );
}
