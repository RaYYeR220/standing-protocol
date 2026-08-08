import { CONTRACTS } from "@/lib/contracts";
import { explorerAddress, MONAD_RPC } from "@/lib/chain";
import { truncateMid } from "@/lib/format";

const REGISTER: { label: string; address: string; kind: string }[] = [
  { label: "CreditManager", address: CONTRACTS.creditManager, kind: "protocol" },
  { label: "StandingPool", address: CONTRACTS.standingPool, kind: "protocol" },
  { label: "StandingRegistry", address: CONTRACTS.standingRegistry, kind: "protocol" },
  { label: "A-Pass registry", address: CONTRACTS.apassRegistry, kind: "cleanverse" },
  { label: "Policy engine", address: CONTRACTS.policy, kind: "cleanverse" },
  { label: "aUSDC", address: CONTRACTS.verifiedAsset, kind: "cleanverse" },
];

/** The address register. Nothing on this console reads from anywhere else. */
export function Footer() {
  return (
    <footer className="mt-6 border-t border-[var(--color-line)] bg-[var(--color-ink-deep)]">
      <div className="mx-auto w-full max-w-[1680px] px-4 py-5 lg:px-6">
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-3">
          <span className="lbl">Address register</span>
          <span className="lbl-micro">RPC {MONAD_RPC.replace("https://", "")}</span>
        </div>
        <ul className="grid grid-cols-1 gap-x-6 gap-y-0 sm:grid-cols-2 xl:grid-cols-3">
          {REGISTER.map((r) => (
            <li
              key={r.address}
              className="flex items-baseline justify-between gap-3 border-b border-[var(--color-line)] py-2"
            >
              <span className="flex items-baseline gap-2">
                <span
                  className={`inline-block h-1.5 w-1.5 shrink-0 translate-y-[-1px] ${
                    r.kind === "protocol"
                      ? "bg-[var(--color-teal)]"
                      : "bg-[var(--color-bone-ghost)]"
                  }`}
                  aria-hidden
                />
                <span className="text-[0.75rem] text-[var(--color-bone-dim)]">{r.label}</span>
              </span>
              <a
                href={explorerAddress(r.address)}
                target="_blank"
                rel="noreferrer"
                title={r.address}
                className="num text-[0.6875rem] text-[var(--color-bone-faint)] hover:text-[var(--color-teal)]"
              >
                {truncateMid(r.address, 10, 8)}
              </a>
            </li>
          ))}
        </ul>
      </div>
    </footer>
  );
}
