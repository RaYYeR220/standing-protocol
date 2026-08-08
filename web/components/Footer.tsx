"use client";

import { useNetwork } from "@/lib/network";
import { truncateMid } from "@/lib/format";

/** The address register. Nothing on this console reads from anywhere else. */
export function Footer() {
  const { deployment, contracts, addressUrl } = useNetwork();

  const register: { label: string; address: string; kind: string }[] = [
    { label: "CreditManager", address: contracts.creditManager, kind: "protocol" },
    { label: "StandingPool", address: contracts.standingPool, kind: "protocol" },
    { label: "StandingRegistry", address: contracts.standingRegistry, kind: "protocol" },
    { label: "A-Pass registry", address: contracts.apassRegistry, kind: "cleanverse" },
    { label: "Policy engine", address: contracts.policy, kind: "cleanverse" },
    { label: "Compliance validator", address: contracts.validator, kind: "cleanverse" },
    { label: "aUSDC", address: contracts.verifiedAsset, kind: "cleanverse" },
  ];

  return (
    <footer className="mt-6 border-t border-[var(--color-line)] bg-[var(--color-ink-deep)]">
      <div className="mx-auto w-full max-w-[1680px] px-4 py-5 lg:px-6">
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-3">
          <span className="lbl">
            Address register · {deployment.chain.name} · chain {deployment.chain.id}
          </span>
          <span className="lbl-micro">RPC {deployment.rpc.replace("https://", "")}</span>
        </div>
        <ul className="grid grid-cols-1 gap-x-6 gap-y-0 sm:grid-cols-2 xl:grid-cols-3">
          {register.map((r) => (
            <li
              key={r.label}
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
                href={addressUrl(r.address)}
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
        <p className="mt-3 max-w-[86ch] text-[0.6875rem] leading-relaxed text-[var(--color-bone-faint)]">
          The protocol&apos;s three contracts are deployed once per chain from identical source.
          Cleanverse&apos;s four are at the same addresses on both, so only the top three change when
          the deployment is switched.
        </p>
      </div>
    </footer>
  );
}
