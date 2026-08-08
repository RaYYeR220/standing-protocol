import { ASSET_DECIMALS } from "./contracts";

/** Splits a fixed-point amount into its integer and fractional halves so the
 *  console can render the significant digits bright and the tail dim. */
export function splitUnits(value: bigint, decimals = ASSET_DECIMALS) {
  const neg = value < 0n;
  const abs = neg ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const frac = (abs % base).toString().padStart(decimals, "0");
  return {
    sign: neg ? "-" : "",
    int: groupDigits(whole.toString()),
    frac,
  };
}

export function groupDigits(s: string) {
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** Flat string form, for copy targets and titles. */
export function formatUnits6(value: bigint, decimals = ASSET_DECIMALS) {
  const { sign, int, frac } = splitUnits(value, decimals);
  return `${sign}${int}.${frac}`;
}

/** Parses user input into the asset's smallest unit. Returns null on garbage. */
export function parseUnits6(input: string, decimals = ASSET_DECIMALS): bigint | null {
  const s = input.trim().replace(/,/g, "");
  if (s === "" || !/^\d*\.?\d*$/.test(s)) return null;
  const [w = "", f = ""] = s.split(".");
  if (f.length > decimals) return null;
  const whole = w === "" ? 0n : BigInt(w);
  const frac = f === "" ? 0n : BigInt(f.padEnd(decimals, "0"));
  return whole * 10n ** BigInt(decimals) + frac;
}

export function bpsToPercent(bps: bigint | number, dp = 2) {
  const n = typeof bps === "bigint" ? Number(bps) : bps;
  return `${(n / 100).toFixed(dp)}%`;
}

export function truncateMid(s: string, head = 6, tail = 4) {
  if (s.length <= head + tail + 1) return s;
  return `${s.slice(0, head)}…${s.slice(-tail)}`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** UTC, unambiguous, sortable-looking. A terminal does not do local time. */
export function formatTimestamp(seconds: bigint | number) {
  const n = Number(seconds);
  if (!n) return "—";
  const d = new Date(n * 1000);
  const p = (x: number) => String(x).padStart(2, "0");
  return `${p(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()} ${p(
    d.getUTCHours(),
  )}:${p(d.getUTCMinutes())}Z`;
}

/** Signed, compact duration relative to now: "in 27d 04h", "12d 09h ago". */
export function relativeTime(seconds: bigint | number, nowMs = Date.now()) {
  const n = Number(seconds);
  if (!n) return "—";
  const delta = n * 1000 - nowMs;
  const abs = Math.abs(delta);
  const d = Math.floor(abs / 86_400_000);
  const h = Math.floor((abs % 86_400_000) / 3_600_000);
  const m = Math.floor((abs % 3_600_000) / 60_000);
  const body = d > 0 ? `${d}d ${String(h).padStart(2, "0")}h` : h > 0 ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m`;
  return delta >= 0 ? `in ${body}` : `${body} ago`;
}

export function durationLabel(seconds: number) {
  const d = Math.floor(seconds / 86_400);
  if (d >= 365) {
    const y = Math.floor(d / 365);
    const rem = d % 365;
    return rem ? `${y}y ${rem}d` : `${y}y`;
  }
  return `${d}d`;
}

/**
 * Pulls the useful part out of a viem error without dumping a stack. A bare
 * `shortMessage` on a revert often ends in a colon, so the meta lines that carry
 * the actual selector are kept — that selector is the evidence.
 */
export function shortError(err: unknown): string {
  if (!err) return "unknown error";
  const e = err as {
    shortMessage?: string;
    metaMessages?: string[];
    details?: string;
    message?: string;
    name?: string;
  };
  const parts: string[] = [];
  if (e.shortMessage) parts.push(e.shortMessage);
  if (Array.isArray(e.metaMessages)) parts.push(...e.metaMessages.slice(0, 2));
  const raw = parts.length
    ? parts.join(" ")
    : e.details || e.message || e.name || String(err);
  return raw.replace(/\s+/g, " ").trim().slice(0, 240);
}

/**
 * The 4-byte selector a revert carried, when the callee's error is not in any ABI
 * we hold. The selector is the only honest thing to show in that case.
 */
export function revertSelector(err: unknown): string | null {
  const e = err as { metaMessages?: string[]; shortMessage?: string; message?: string };
  const hay = [e?.shortMessage, ...(e?.metaMessages ?? []), e?.message]
    .filter(Boolean)
    .join(" ");
  const m = hay.match(/0x[0-9a-fA-F]{8}\b/);
  return m ? m[0] : null;
}

export function isAddressish(s: string) {
  return /^0x[0-9a-fA-F]{40}$/.test(s.trim());
}
