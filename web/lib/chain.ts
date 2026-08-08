import { defineChain } from "viem";

export const MONAD_RPC = "https://testnet-rpc.monad.xyz";
export const MONAD_EXPLORER = "https://testnet.monadexplorer.com";

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: [MONAD_RPC] },
  },
  blockExplorers: {
    default: { name: "Monad Explorer", url: MONAD_EXPLORER },
  },
  testnet: true,
});

export function explorerAddress(address: string) {
  return `${MONAD_EXPLORER}/address/${address}`;
}

export function explorerTx(hash: string) {
  return `${MONAD_EXPLORER}/tx/${hash}`;
}
