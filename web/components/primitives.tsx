"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { explorerAddress } from "@/lib/chain";
import { ASSET_DECIMALS, ASSET_SYMBOL } from "@/lib/contracts";
import {
  bpsToPercent,
  formatTimestamp,
  relativeTime,
  shortError,
  splitUnits,
  truncateMid,
} from "@/lib/format";
import type { ReadState } from "@/lib/types";

/* -------------------------------------------------------------- panel chrome */

export function Panel({
  label,
  sub,
  right,
  children,
  className = "",
  bodyClass = "p-4",
  tone = "normal",
}: {
  label: string;
  sub?: ReactNode;
  right?: ReactNode;
  children: ReactNode;
  className?: string;
  bodyClass?: string;
  tone?: "normal" | "pass" | "deny";
}) {
  const edge =
    tone === "pass"
      ? "before:!border-[var(--color-teal)] after:!border-[var(--color-teal)]"
      : tone === "deny"
        ? "before:!border-[var(--color-refuse)] after:!border-[var(--color-refuse)]"
        : "";
  return (
    <section className={`panel ${edge} ${className}`}>
      <header className="panel-head">
        <div className="flex min-w-0 items-baseline gap-2.5">
          <h2 className="lbl shrink-0 whitespace-nowrap !text-[var(--color-bone-dim)]">{label}</h2>
          {sub ? <span className="lbl-micro min-w-0 truncate">{sub}</span> : null}
        </div>
        {right ? <div className="flex shrink-0 items-center gap-2">{right}</div> : null}
      </header>
      <div className={bodyClass}>{children}</div>
    </section>
  );
}

/** A label/value line with dot leaders, the console's default data row. */
export function Row({
  label,
  note,
  children,
  dense = false,
}: {
  label: string;
  note?: ReactNode;
  children: ReactNode;
  dense?: boolean;
}) {
  return (
    <div className={`rowline ${dense ? "!py-1" : ""}`}>
      <div className="flex min-w-0 shrink basis-auto flex-col gap-1">
        <span className="lbl">{label}</span>
        {note ? (
          <span className="lbl-micro !leading-[1.4] !tracking-[0.08em] normal-case">{note}</span>
        ) : null}
      </div>
      <span className="leader" />
      <div className="shrink-0 text-right">{children}</div>
    </div>
  );
}

export function Tag({
  tone = "idle",
  children,
  title,
}: {
  tone?: "pass" | "deny" | "idle";
  children: ReactNode;
  title?: string;
}) {
  return (
    <span className={`chip chip-${tone}`} title={title}>
      {children}
    </span>
  );
}

/* ------------------------------------------------------------- read plumbing */

/**
 * Every on-chain read is rendered through here. A failed read shows as a fault,
 * never as a zero — a fabricated number on an underwriting screen is worse than
 * no number at all.
 */
export function R<T>({
  read,
  children,
  skeleton = "······",
}: {
  read: ReadState<T>;
  children: (value: T) => ReactNode;
  skeleton?: string;
}) {
  if (read.error) {
    return (
      <span
        className="chip chip-deny cursor-help"
        title={shortError(read.error)}
        role="status"
      >
        RPC FAULT
      </span>
    );
  }
  if (read.data === undefined) {
    return <span className="num text-[var(--color-bone-ghost)] sp-pulse">{skeleton}</span>;
  }
  return <>{children(read.data)}</>;
}

/** Re-keys its child when the value changes so the flash animation replays. */
function useChangeKey(token: string) {
  const prev = useRef<string | null>(null);
  const [key, setKey] = useState(0);
  useEffect(() => {
    if (prev.current !== null && prev.current !== token) setKey((k) => k + 1);
    prev.current = token;
  }, [token]);
  return key;
}

/* ------------------------------------------------------------------- numbers */

/**
 * A fixed-point amount. Significant digits bright, the tail dim — the whole number
 * is on screen, but the eye lands on the part that matters.
 */
export function Amount({
  value,
  decimals = ASSET_DECIMALS,
  unit = ASSET_SYMBOL,
  size = "md",
  tone = "normal",
  flash = true,
}: {
  value: bigint;
  decimals?: number;
  unit?: string | null;
  size?: "sm" | "md" | "lg" | "xl";
  tone?: "normal" | "teal" | "refuse" | "dim";
  flash?: boolean;
}) {
  const { sign, int, frac } = splitUnits(value, decimals);
  const key = useChangeKey(`${value}`);
  const sizes = {
    sm: "text-[0.6875rem]",
    md: "text-[0.8125rem]",
    lg: "text-[1.0625rem]",
    xl: "text-[1.75rem] leading-none",
  } as const;
  const tones = {
    normal: "text-[var(--color-bone)]",
    teal: "text-[var(--color-teal)]",
    refuse: "text-[var(--color-refuse)]",
    dim: "text-[var(--color-bone-dim)]",
  } as const;
  // The significant tail: first two decimal places read as cents, the rest is proof.
  const lead = frac.slice(0, 2);
  const rest = frac.slice(2);
  return (
    <span className="inline-flex items-baseline gap-1.5 whitespace-nowrap">
      <span
        key={flash ? key : undefined}
        className={`num ${sizes[size]} ${tones[tone]} ${flash && key ? "sp-flash" : ""}`}
      >
        {sign}
        {int}
        <span className="opacity-80">.{lead}</span>
        <span className="opacity-40">{rest}</span>
      </span>
      {unit ? <span className="lbl-micro !text-[var(--color-bone-faint)]">{unit}</span> : null}
    </span>
  );
}

/** A plain integer, grouped and tabular. */
export function Int({
  value,
  size = "md",
  tone = "normal",
  suffix,
}: {
  value: bigint | number;
  size?: "sm" | "md" | "lg" | "xl";
  tone?: "normal" | "teal" | "refuse" | "dim";
  suffix?: string;
}) {
  const n = typeof value === "bigint" ? value : BigInt(Math.trunc(value));
  const key = useChangeKey(`${n}`);
  const sizes = {
    sm: "text-[0.6875rem]",
    md: "text-[0.8125rem]",
    lg: "text-[1.0625rem]",
    xl: "text-[1.75rem] leading-none",
  } as const;
  const tones = {
    normal: "text-[var(--color-bone)]",
    teal: "text-[var(--color-teal)]",
    refuse: "text-[var(--color-refuse)]",
    dim: "text-[var(--color-bone-dim)]",
  } as const;
  return (
    <span className="inline-flex items-baseline gap-1.5 whitespace-nowrap">
      <span key={key} className={`num ${sizes[size]} ${tones[tone]} ${key ? "sp-flash" : ""}`}>
        {n.toLocaleString("en-US")}
      </span>
      {suffix ? <span className="lbl-micro !text-[var(--color-bone-faint)]">{suffix}</span> : null}
    </span>
  );
}

export function Pct({
  bps,
  size = "md",
  tone = "normal",
}: {
  bps: bigint | number;
  size?: "sm" | "md" | "lg" | "xl";
  tone?: "normal" | "teal" | "refuse" | "dim";
}) {
  const key = useChangeKey(`${bps}`);
  const sizes = {
    sm: "text-[0.6875rem]",
    md: "text-[0.8125rem]",
    lg: "text-[1.0625rem]",
    xl: "text-[1.75rem] leading-none",
  } as const;
  const tones = {
    normal: "text-[var(--color-bone)]",
    teal: "text-[var(--color-teal)]",
    refuse: "text-[var(--color-refuse)]",
    dim: "text-[var(--color-bone-dim)]",
  } as const;
  return (
    <span key={key} className={`num ${sizes[size]} ${tones[tone]} ${key ? "sp-flash" : ""}`}>
      {bpsToPercent(bps)}
    </span>
  );
}

/* ---------------------------------------------------------- addresses, hashes */

export function Addr({
  address,
  label,
  head = 6,
  tail = 4,
  tone = "normal",
  link = true,
}: {
  address: string;
  label?: string;
  head?: number;
  tail?: number;
  tone?: "normal" | "teal" | "refuse" | "dim";
  link?: boolean;
}) {
  const tones = {
    normal: "text-[var(--color-bone)]",
    teal: "text-[var(--color-teal)]",
    refuse: "text-[var(--color-refuse)]",
    dim: "text-[var(--color-bone-dim)]",
  } as const;
  const body = (
    <span className={`num text-[0.75rem] ${tones[tone]}`}>
      {label ? <span className="lbl-micro mr-1.5">{label}</span> : null}
      {truncateMid(address, head, tail)}
    </span>
  );
  if (!link) return body;
  return (
    <a
      href={explorerAddress(address)}
      target="_blank"
      rel="noreferrer"
      title={address}
      className="inline-flex items-center gap-1 border-b border-dotted border-[var(--color-bone-ghost)] hover:border-[var(--color-teal)] hover:text-[var(--color-teal)]"
    >
      {body}
    </a>
  );
}

export function Hash({ value, head = 10, tail = 8 }: { value: string; head?: number; tail?: number }) {
  return (
    <span className="num text-[0.75rem] text-[var(--color-bone-dim)]" title={value}>
      {truncateMid(value, head, tail)}
    </span>
  );
}

export function Stamp({ seconds, nowMs }: { seconds: bigint | number; nowMs?: number }) {
  return (
    <span className="inline-flex flex-col items-end gap-0.5">
      <span className="num text-[0.75rem]">{formatTimestamp(seconds)}</span>
      <span className="lbl-micro !tracking-[0.12em]">{relativeTime(seconds, nowMs)}</span>
    </span>
  );
}

/* --------------------------------------------------------------------- meters */

/** A hairline bar. Used for component-against-ceiling, never for a score. */
export function Bar({
  value,
  max,
  tone = "teal",
  height = 3,
}: {
  value: number;
  max: number;
  tone?: "teal" | "refuse" | "dim";
  height?: number;
}) {
  const pct = max <= 0 ? 0 : Math.max(0, Math.min(100, (value / max) * 100));
  const fill =
    tone === "refuse"
      ? "var(--color-refuse)"
      : tone === "dim"
        ? "var(--color-bone-ghost)"
        : "var(--color-teal)";
  return (
    <div
      className="w-full bg-[var(--color-panel-sunk)] border border-[var(--color-line)]"
      style={{ height }}
      role="presentation"
    >
      <div
        style={{
          width: `${pct}%`,
          height: "100%",
          background: fill,
          transition: "width 420ms cubic-bezier(0.2,0,0.1,1)",
        }}
      />
    </div>
  );
}

/* ---------------------------------------------------------------- misc bits */

export function Fault({ error, what }: { error: unknown; what: string }) {
  return (
    <div className="border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-3">
      <div className="lbl !text-[var(--color-refuse)]">RPC FAULT · {what}</div>
      <p className="num mt-1.5 text-[0.6875rem] break-words text-[var(--color-refuse)] opacity-80">
        {shortError(error)}
      </p>
      <p className="mt-2 text-[0.6875rem] text-[var(--color-bone-faint)]">
        This value is not being substituted. Nothing is shown in its place.
      </p>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return (
    <div className="border border-dashed border-[var(--color-line-lift)] px-4 py-6 text-center">
      <p className="lbl !tracking-[0.2em]">{children}</p>
    </div>
  );
}

/** A short passage of explanatory prose. Used sparingly — this is a terminal. */
export function Note({ children }: { children: ReactNode }) {
  return (
    <p className="max-w-[62ch] text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
      {children}
    </p>
  );
}
