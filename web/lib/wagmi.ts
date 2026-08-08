// `injected` is imported from the wagmi root rather than `wagmi/connectors`: the
// connectors barrel drags in the whole hosted-wallet SDK tree, which this console
// has no use for and which does not resolve cleanly in a browser bundle.
import { createConfig, http, injected } from "wagmi";
import { baseSepolia, BASE_SEPOLIA_RPC, monadTestnet, MONAD_RPC } from "./chain";

const transport = (url: string) =>
  http(url, {
    batch: { wait: 20, batchSize: 6 },
    retryCount: 3,
    retryDelay: 350,
    timeout: 25_000,
  });

/**
 * Both deployments are registered so every read and write can name its chain
 * explicitly. Nothing falls back to "whatever the wallet happens to be on".
 */
export const wagmiConfig = createConfig({
  chains: [monadTestnet, baseSepolia],
  connectors: [injected({ shimDisconnect: true })],
  transports: {
    [monadTestnet.id]: transport(MONAD_RPC),
    [baseSepolia.id]: transport(BASE_SEPOLIA_RPC),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
