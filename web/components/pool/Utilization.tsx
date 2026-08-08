"use client";

import { bpsToPercent } from "@/lib/format";

/**
 * Utilization against the ceiling the pool enforces on itself. The ceiling is the
 * interesting number — it is what keeps redemption liquid when the book turns.
 */
export function Utilization({
  bps,
  ceilingBps,
}: {
  bps: bigint | undefined;
  ceilingBps: bigint | undefined;
}) {
  const v = bps === undefined ? 0 : Number(bps);
  const ceiling = ceilingBps === undefined ? 8000 : Number(ceilingBps);
  const pct = Math.max(0, Math.min(100, v / 100));
  const ceilingPct = Math.max(0, Math.min(100, ceiling / 100));
  const hot = v >= ceiling;

  return (
    <div>
      <div className="mb-2 flex items-baseline justify-between">
        <span className="lbl">Utilization</span>
        <span className="num text-[1.0625rem]">
          {bps === undefined ? "······" : bpsToPercent(v)}
        </span>
      </div>
      <div className="relative h-6 border border-[var(--color-line)] bg-[var(--color-panel-sunk)]">
        {/* filled */}
        <div
          className="absolute inset-y-0 left-0"
          style={{
            width: `${pct}%`,
            background: hot ? "var(--color-refuse)" : "var(--color-teal-deep)",
            transition: "width 480ms cubic-bezier(0.2,0,0.1,1), background-color 240ms linear",
          }}
        />
        {/* the ceiling */}
        <div
          className="absolute inset-y-0 border-l border-dashed border-[var(--color-bone-dim)]"
          style={{ left: `${ceilingPct}%` }}
          aria-hidden
        />
        {/* hatching above the ceiling */}
        <div
          className="absolute inset-y-0 right-0 opacity-[0.18]"
          style={{
            left: `${ceilingPct}%`,
            backgroundImage:
              "repeating-linear-gradient(45deg, var(--color-bone-faint) 0 1px, transparent 1px 6px)",
          }}
          aria-hidden
        />
      </div>
      <div className="mt-1.5 flex justify-between">
        <span className="lbl-micro">0%</span>
        <span className="lbl-micro !text-[var(--color-bone-dim)]">
          ceiling {bpsToPercent(ceiling, 0)}
        </span>
        <span className="lbl-micro">100%</span>
      </div>
    </div>
  );
}
