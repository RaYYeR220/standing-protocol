export function ScreenHead({ title, blurb }: { title: string; blurb: string }) {
  return (
    <div className="flex flex-col gap-2 border-b border-[var(--color-line)] pb-4 lg:flex-row lg:items-baseline lg:gap-8">
      <h1 className="hdg shrink-0 text-[1.375rem] leading-none">{title}</h1>
      <p className="max-w-[78ch] text-[0.8125rem] leading-relaxed text-[var(--color-bone-dim)]">
        {blurb}
      </p>
    </div>
  );
}
