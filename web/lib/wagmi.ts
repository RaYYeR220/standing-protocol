// `injected` is imported from the wagmi root rather than `wagmi/connectors`: the
// connectors barrel drags in the whole hosted-wallet SDK tree, which this console
// has no use for and which does not resolve cleanly in a browser bundle.
import { createConfig, http, injected } from "wagmi";
import { monadTestnet, MONAD_RPC } from "./chain";

export const wagmiConfig = createConfig({
  chains: [monadTestnet],
  connectors: [injected({ shimDisconnect: true })],
  transports: {
    [monadTestnet.id]: http(MONAD_RPC, {
      batch: { wait: 20, batchSize: 6 },
      retryCount: 3,
      retryDelay: 350,
      timeout: 25_000,
    }),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
