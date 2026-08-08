import { createPublicClient, http, type PublicClient } from "viem";
import { NETWORKS, type NetworkKey } from "./chain";

/**
 * Both public endpoints rate-limit large JSON-RPC batches, so batches are kept
 * small and the loan-book sweep is chunked rather than fired all at once.
 * A dropped read surfaces as a visible fault; it is never papered over.
 */
function build(key: NetworkKey): PublicClient {
  const net = NETWORKS[key];
  return createPublicClient({
    chain: net.chain,
    transport: http(net.rpc, {
      batch: { wait: 20, batchSize: 6 },
      retryCount: 3,
      retryDelay: 350,
      timeout: 25_000,
    }),
  });
}

const clients = new Map<NetworkKey, PublicClient>();

/** One client per deployment, built on first use and kept. */
export function publicClientFor(key: NetworkKey): PublicClient {
  const held = clients.get(key);
  if (held) return held;
  const made = build(key);
  clients.set(key, made);
  return made;
}

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
