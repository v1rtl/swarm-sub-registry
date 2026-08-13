import {
  createWalletClient,
  fallback,
  http,
  isAddress,
  isHex,
  publicActions,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { gnosis, sepolia } from "viem/chains";
import type { Chain } from "viem";
import type { KeeperMode } from "ethswarm-volume-keeper";

/**
 * Chains this worker can be pointed at. Add one here to support it — its viem
 * `Chain` must carry `contracts.multicall3`, which is how every read is
 * batched.
 */
const CHAINS: Record<number, Chain> = {
  [gnosis.id]: gnosis,
  [sepolia.id]: sepolia,
};

export interface Env {
  REGISTRY_ADDRESS: string;
  CHAIN_ID: string;
  /** `wrangler secret put PRIVATE_KEY`, or `.dev.vars` locally. */
  PRIVATE_KEY: string;
  /**
   * Your RPC endpoint. Comma-separate several to fail over between them —
   * they are tried in order. Required: this worker ships no endpoints of its
   * own.
   */
  RPC_URL: string;
  /** Comma-separated volume ids. Present ⇒ maintain only these. */
  VOLUME_IDS?: string;
  DRY_RUN?: string;
  MAX_IDS_PER_TX?: string;
  MAX_TX_PER_CYCLE?: string;
  PAGE_SIZE?: string;
  /** Warn when the keeper's native balance drops below this. */
  MIN_BALANCE_WEI?: string;
}

const list = (raw: string | undefined): string[] =>
  (raw ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

const num = (raw: string | undefined): number | undefined =>
  raw ? Number(raw) : undefined;

/**
 * A wallet client with public actions — what `runKeeperCycle` expects.
 *
 * Endpoints come from RPC_URL and nowhere else. List more than one and they
 * go behind viem's `fallback`: each gets `retryCount: 0` so a dead one is
 * abandoned immediately, `fallback` owns the retry budget and walks the list,
 * and ranking demotes one that is merely slow.
 */
export function buildClient(env: Env) {
  const chainId = Number(env.CHAIN_ID);
  const chain = CHAINS[chainId];
  if (!chain) {
    throw new Error(
      `unsupported CHAIN_ID ${env.CHAIN_ID} (supported: ${Object.keys(CHAINS).join(", ")})`,
    );
  }
  if (!isHex(env.PRIVATE_KEY) || env.PRIVATE_KEY.length !== 66) {
    throw new Error("PRIVATE_KEY must be a 0x-prefixed 32-byte hex string");
  }

  const endpoints = list(env.RPC_URL);
  if (endpoints.length === 0) throw new Error("RPC_URL is required");

  return createWalletClient({
    account: privateKeyToAccount(env.PRIVATE_KEY),
    chain,
    transport: fallback(
      endpoints.map((url) => http(url, { retryCount: 0, timeout: 10_000 })),
      {
        retryCount: 2,
        ...(endpoints.length > 1
          ? { rank: { interval: 60_000, sampleCount: 5 } }
          : {}),
      },
    ),
  }).extend(publicActions);
}

export interface KeeperOptions {
  registry: Address;
  mode: KeeperMode;
  dryRun: boolean;
  maxIdsPerTx?: number;
  maxTxPerCycle?: number;
  pageSize?: number;
  minBalanceWei: bigint;
}

export function readOptions(env: Env): KeeperOptions {
  if (!isAddress(env.REGISTRY_ADDRESS)) {
    throw new Error(`REGISTRY_ADDRESS is not an address: ${env.REGISTRY_ADDRESS}`);
  }

  const volumeIds = list(env.VOLUME_IDS);
  for (const id of volumeIds) {
    if (!isHex(id) || id.length !== 66) {
      throw new Error(`VOLUME_IDS entry is not a 32-byte hex string: ${id}`);
    }
  }

  return {
    registry: env.REGISTRY_ADDRESS,
    mode: volumeIds.length
      ? { type: "selected", volumeIds: volumeIds as Hex[] }
      : { type: "all" },
    dryRun: !!env.DRY_RUN && !["false", "0", "no"].includes(env.DRY_RUN.toLowerCase()),
    maxIdsPerTx: num(env.MAX_IDS_PER_TX),
    maxTxPerCycle: num(env.MAX_TX_PER_CYCLE),
    pageSize: num(env.PAGE_SIZE),
    minBalanceWei: env.MIN_BALANCE_WEI ? BigInt(env.MIN_BALANCE_WEI) : 0n,
  };
}
