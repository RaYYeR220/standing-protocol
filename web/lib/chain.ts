import { defineChain, type Address } from "viem";

/**
 * The protocol is deployed twice from identical source. Everything that differs
 * between the two deployments lives in this file and travels together: RPC,
 * explorer and address set are swapped as one unit, never piecemeal.
 */
export type NetworkKey = "monad" | "base";

export type ContractSet = {
  creditManager: Address;
  standingPool: Address;
  standingRegistry: Address;
  apassRegistry: Address;
  policy: Address;
  validator: Address;
  verifiedAsset: Address;
};

export const MONAD_RPC = "https://testnet-rpc.monad.xyz";
export const MONAD_EXPLORER = "https://testnet.monadexplorer.com";
export const BASE_SEPOLIA_RPC = "https://sepolia.base.org";
export const BASE_SEPOLIA_EXPLORER = "https://sepolia.basescan.org";

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

export const baseSepolia = defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [BASE_SEPOLIA_RPC] },
  },
  blockExplorers: {
    default: { name: "Basescan", url: BASE_SEPOLIA_EXPLORER },
  },
  testnet: true,
});

/**
 * Cleanverse deployed its own contracts at the same addresses on both chains, so
 * only the protocol's three contracts move between deployments.
 */
const CLEANVERSE = {
  apassRegistry: "0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9",
  policy: "0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd",
  validator: "0xaC7e5179C2C7f03f209136886c172eb34F161792",
  verifiedAsset: "0xaC0893567D43C3E7e6e35a72803df05416C1f20D",
} as const satisfies Record<string, Address>;

/** Kept as a literal union so every read and write can name its chain id exactly. */
export type ProtocolChain = typeof monadTestnet | typeof baseSepolia;
export type ChainId = ProtocolChain["id"];

export type Deployment = {
  key: NetworkKey;
  /** Rail readout. */
  label: string;
  /** Switch face. */
  short: string;
  chain: ProtocolChain;
  rpc: string;
  explorer: string;
  contracts: ContractSet;
};

/** Mirrors contracts/deployments/*.json. Nothing on this console reads elsewhere. */
export const NETWORKS: Record<NetworkKey, Deployment> = {
  monad: {
    key: "monad",
    label: "MONAD TESTNET",
    short: "Monad",
    chain: monadTestnet,
    rpc: MONAD_RPC,
    explorer: MONAD_EXPLORER,
    contracts: {
      creditManager: "0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74",
      standingPool: "0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D",
      standingRegistry: "0x2bD8832C9Bc98df47F256507a903B0338D96C0b5",
      ...CLEANVERSE,
    },
  },
  base: {
    key: "base",
    label: "BASE SEPOLIA",
    short: "Base",
    chain: baseSepolia,
    rpc: BASE_SEPOLIA_RPC,
    explorer: BASE_SEPOLIA_EXPLORER,
    contracts: {
      creditManager: "0x324719787E22a7c2c3E77bc84484317c2D2D1093",
      standingPool: "0x5ae228215dae30EC07D0196B13179CFA00146D03",
      standingRegistry: "0xE066669d09afd30444429003987b9E7BcA970F19",
      ...CLEANVERSE,
    },
  },
};

export const NETWORK_KEYS = ["monad", "base"] as const satisfies readonly NetworkKey[];

/** Monad is where the protocol was written; Base Sepolia is where the book has rows. */
export const DEFAULT_NETWORK: NetworkKey = "monad";

export function isNetworkKey(v: string | null | undefined): v is NetworkKey {
  return v === "monad" || v === "base";
}

export function explorerAddress(explorer: string, address: string) {
  return `${explorer}/address/${address}`;
}

export function explorerTx(explorer: string, hash: string) {
  return `${explorer}/tx/${hash}`;
}
