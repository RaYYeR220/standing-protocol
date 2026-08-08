/**
 * The brand mark: a rising colonnade of five pillars, the tallest capped in teal.
 * The same motif carries the score meter — a score is a colonnade you have built.
 */
export function Mark({ size = 22, className = "" }: { size?: number; className?: string }) {
  // x, height (of 24), each pillar 3 wide with 1 gap
  const pillars = [
    { x: 0, h: 7 },
    { x: 4, h: 11 },
    { x: 8, h: 15 },
    { x: 12, h: 19 },
    { x: 16, h: 24 },
  ];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 19 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      {pillars.map((p, i) => {
        const last = i === pillars.length - 1;
        return (
          <g key={p.x}>
            <rect
              x={p.x}
              y={24 - p.h}
              width={3}
              height={p.h}
              fill={last ? "var(--color-teal)" : "var(--color-bone)"}
              opacity={last ? 1 : 0.34 + i * 0.11}
            />
            {last && <rect x={p.x - 1} y={0} width={5} height={2.5} fill="var(--color-teal)" />}
          </g>
        );
      })}
    </svg>
  );
}
