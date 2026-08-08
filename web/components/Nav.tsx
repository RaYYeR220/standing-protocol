"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect } from "react";

const TABS = [
  { key: "1", href: "/", label: "Borrower", note: "credential · score · terms" },
  { key: "2", href: "/pool", label: "Pool", note: "supply side · ERC-4626" },
  { key: "3", href: "/compliance", label: "Compliance", note: "live gate evaluation" },
  { key: "4", href: "/book", label: "Loan Book", note: "every position" },
] as const;

/** Numbered like a terminal's function keys, and the keys actually work. */
export function Nav() {
  const pathname = usePathname();
  const router = useRouter();

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target as HTMLElement | null;
      if (t && ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName)) return;
      const tab = TABS.find((x) => x.key === e.key);
      if (tab) {
        e.preventDefault();
        router.push(tab.href);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [router]);

  return (
    <nav className="sticky top-[57px] z-20 border-b border-[var(--color-line)] bg-[var(--color-ink)]/95 backdrop-blur-sm">
      <div className="mx-auto w-full max-w-[1680px] px-4 lg:px-6">
        <ul className="-mx-2 flex overflow-x-auto">
          {TABS.map((tab) => {
            const active = pathname === tab.href;
            return (
              <li key={tab.href} className="shrink-0">
                <Link
                  href={tab.href}
                  className={`group relative flex items-baseline gap-2.5 px-4 py-2.5 transition-colors ${
                    active
                      ? "text-[var(--color-bone)]"
                      : "text-[var(--color-bone-faint)] hover:text-[var(--color-bone-dim)]"
                  }`}
                >
                  <span
                    className={`num text-[0.625rem] leading-none ${
                      active ? "text-[var(--color-teal)]" : "text-[var(--color-bone-ghost)]"
                    }`}
                  >
                    [{tab.key}]
                  </span>
                  <span className="whitespace-nowrap text-[0.8125rem] font-medium tracking-[-0.01em]">
                    {tab.label}
                  </span>
                  <span className="lbl-micro hidden !text-[var(--color-bone-ghost)] xl:inline">
                    {tab.note}
                  </span>
                  <span
                    aria-hidden
                    className={`absolute inset-x-0 bottom-[-1px] h-px transition-colors ${
                      active ? "bg-[var(--color-teal)]" : "bg-transparent"
                    }`}
                  />
                </Link>
              </li>
            );
          })}
        </ul>
      </div>
    </nav>
  );
}
