"use client";

import { useSubject } from "@/lib/subject";
import { REFERENCE_WALLETS } from "@/lib/contracts";
import { Mark } from "./Mark";

/** Shown when the subject field is empty. A terminal waiting for an instrument. */
export function AwaitSubject({ what }: { what: string }) {
  const { setRaw } = useSubject();
  return (
    <div className="panel">
      <div className="flex flex-col items-center gap-5 px-6 py-16 text-center">
        <Mark size={34} className="opacity-60" />
        <div>
          <div className="num text-[0.875rem] text-[var(--color-bone-dim)]">
            AWAITING SUBJECT
            <span className="sp-caret ml-1 text-[var(--color-teal)]">_</span>
          </div>
          <p className="mt-3 max-w-[52ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-faint)]">
            Connect a wallet or paste {what} into the subject field above. Everything on this screen
            is read live from Monad testnet — nothing is cached, seeded or simulated.
          </p>
        </div>
        <div className="flex flex-wrap justify-center gap-2">
          {REFERENCE_WALLETS.map((w) => (
            <button key={w.address} className="btn" onClick={() => setRaw(w.address)}>
              Examine {w.label}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
