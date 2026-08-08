import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
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
