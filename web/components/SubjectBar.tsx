"use client";

import { useAccount } from "wagmi";
import { useSubject } from "@/lib/subject";
import { REFERENCE_WALLETS } from "@/lib/contracts";
import { isAddressish } from "@/lib/format";

/**
 * The address under examination. One field, shared by every screen, so the whole
 * terminal is always pointed at the same subject.
 */
export function SubjectBar() {
  const { raw, setRaw, subject, pinnedToWallet, followWallet } = useSubject();
  const { address, isConnected } = useAccount();

  const invalid = raw.trim().length > 0 && !isAddressish(raw);

  return (
    <div className="border-b border-[var(--color-line)] bg-[var(--color-panel-sunk)]">
      <div className="mx-auto flex w-full max-w-[1680px] flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2.5 lg:px-6">
        <label className="lbl shrink-0" htmlFor="subject">
          Subject
        </label>

        <div className="relative min-w-[18rem] flex-1 basis-[22rem]">
          <input
            id="subject"
            className={`field !py-1.5 pr-24 ${
              invalid ? "!border-[var(--color-refuse)]" : subject ? "!border-[var(--color-teal-deep)]" : ""
            }`}
            spellCheck={false}
            autoComplete="off"
            placeholder="0x…  paste any address to examine it"
            value={raw}
            onChange={(e) => setRaw(e.target.value)}
          />
          <span className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2">
            {invalid ? (
              <span className="chip chip-deny">MALFORMED</span>
            ) : subject ? (
              <span className="chip chip-pass">RESOLVED</span>
            ) : (
              <span className="lbl-micro">awaiting</span>
            )}
          </span>
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          {isConnected && address ? (
            <button
              className={`btn !px-2.5 !py-1 ${pinnedToWallet ? "btn-key" : ""}`}
              onClick={followWallet}
              title="Track the connected wallet"
            >
              My Wallet
            </button>
          ) : null}
          {REFERENCE_WALLETS.map((w) => (
            <button
              key={w.address}
              className={`btn !px-2.5 !py-1 ${
                subject?.toLowerCase() === w.address.toLowerCase() ? "btn-key" : ""
              }`}
              onClick={() => setRaw(w.address)}
              title={w.address}
            >
              {w.label}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
