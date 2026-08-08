"use client";

import { useEffect, useState } from "react";

const PILLARS = 25;

/**
 * The score meter, rendered as the mark itself: a rising colonnade, one pillar per
 * forty points, the tallest standing pillar capped. A progress bar would say the
 * score is a fraction of something. A colonnade says it was built.
 */
export function Colonnade({
  score,
  min,
  max,
  height = 148,
}: {
  score: number;
  min: number;
  max: number;
  height?: number;
}) {
  const [seated, setSeated] = useState(false);
  useEffect(() => {
    const t = requestAnimationFrame(() => setSeated(true));
    return () => cancelAnimationFrame(t);
  }, []);

  const perPillar = max / PILLARS;
  const litCount = Math.max(0, Math.min(PILLARS, Math.ceil(score / perPillar)));
  const floorIndex = Math.round(min / perPillar);
  const clears = score >= min;

  return (
    <div className="relative select-none" style={{ height }}>
      {/* the floor: the line below which no amount of collateral buys a loan */}
      <div
        className="pointer-events-none absolute inset-y-0 z-10 border-l border-dashed border-[var(--color-bone-faint)]"
        style={{ left: `${(floorIndex / PILLARS) * 100}%` }}
        aria-hidden
      >
        <span className="lbl-micro absolute -top-0.5 left-1.5 whitespace-nowrap !text-[var(--color-bone-dim)]">
          Floor {min}
        </span>
      </div>

      <div
        className="grid h-full items-end"
        style={{ gridTemplateColumns: `repeat(${PILLARS}, minmax(0, 1fr))`, columnGap: "2px" }}
        role="img"
        aria-label={`Standing score ${score} of ${max}, minimum ${min}`}
      >
        {Array.from({ length: PILLARS }, (_, i) => {
          // The colonnade rises whether or not it is lit — the silhouette is fixed.
          const h = 20 + (i / (PILLARS - 1)) * 80;
          const lit = i < litCount;
          const capstone = lit && i === litCount - 1;
          const belowFloor = i < floorIndex;

          const fill = !lit
            ? "var(--color-panel-lift)"
            : clears
              ? capstone
                ? "var(--color-teal)"
                : "var(--color-teal-deep)"
              : capstone
                ? "var(--color-refuse)"
                : "var(--color-refuse-deep)";

          return (
            <div key={i} className="relative h-full">
              <div
                className="absolute inset-x-0 bottom-0"
                style={{
                  height: `${h}%`,
                  background: fill,
                  outline: lit ? "none" : `1px solid var(--color-line)`,
                  outlineOffset: "-1px",
                  opacity: lit ? 1 : belowFloor ? 0.9 : 0.55,
                  transform: seated ? "scaleY(1)" : "scaleY(0)",
                  transformOrigin: "bottom",
                  transition: `transform 460ms cubic-bezier(0.2,0,0.1,1) ${i * 18}ms, background-color 260ms linear, height 380ms cubic-bezier(0.2,0,0.1,1)`,
                }}
              >
                {capstone ? (
                  <span
                    className="absolute inset-x-[-1px] top-[-3px] h-[3px]"
                    style={{
                      background: clears ? "var(--color-teal)" : "var(--color-refuse)",
                      boxShadow: clears
                        ? "0 0 10px 1px rgba(47,212,200,0.55)"
                        : "0 0 10px 1px rgba(255,107,90,0.45)",
                    }}
                    aria-hidden
                  />
                ) : null}
              </div>
            </div>
          );
        })}
      </div>

      {/* baseline */}
      <div className="absolute inset-x-0 bottom-0 h-px bg-[var(--color-line-hot)]" aria-hidden />
    </div>
  );
}
