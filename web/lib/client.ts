import { createPublicClient, http } from "viem";
import { monadTestnet, MONAD_RPC } from "./chain";

/**
 * The public Monad testnet endpoint rate-limits large JSON-RPC batches, so batches
 * are kept small and the loan-book sweep is chunked rather than fired all at once.
 * A dropped read surfaces as a visible fault; it is never papered over.
 */
export const publicClient = createPublicClient({
  chain: monadTestnet,
  transport: http(MONAD_RPC, {
    batch: { wait: 20, batchSize: 6 },
    retryCount: 3,
    retryDelay: 350,
    timeout: 25_000,
  }),
});

/** Runs reads in bounded waves so a sweep cannot trip the endpoint's rate limit. */
export async function inWaves<T, R>(
  items: T[],
  size: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(...(await Promise.all(items.slice(i, i + size).map(fn))));
  }
  return out;
}
