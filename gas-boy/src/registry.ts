import {
  createPublicClient,
  createWalletClient,
  http,
  webSocket,
  fallback,
  zeroAddress,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Account,
  type Transport,
  type ReadContractReturnType,
} from "viem";
import { sepolia, gnosis } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { registryAbi, postageAbi } from "./abi";

export interface Env {
  RPC_URL: string;
  CHAIN_ID: string;
  REGISTRY_ADDRESS: `0x${string}`;
  POSTAGE_ADDRESS: `0x${string}`;
  PRIVATE_KEY: string;
  // Page size for getActiveVolumes; default 100 if unset.
  PAGE_SIZE?: string;
}

export interface RunResult {
  ok: boolean;
  skipped?: string;
  activeCount?: number;
  dueCount?: number;
  deadCount?: number;
  pagesRead?: number;
  txHash?: Hex;
  blockNumber?: string;
  gasUsed?: string;
  error?: string;
  durationMs: number;
}

// Supported chains. viem's definitions already include the canonical
// Multicall3 deployment, so there's nothing to inject. `fallbacks` are free
// public RPCs tried (via viem's `fallback`) behind the configured RPC_URL so
// one throttled provider can't stall a cycle; built once at module scope.
const CHAINS: Record<number, { chain: Chain; fallbacks: Transport[] }> = {
  [gnosis.id]: {
    chain: gnosis,
    fallbacks: [
      http("https://gnosis-rpc.publicnode.com", { retryCount: 0 }),
      webSocket("wss://gnosis-rpc.publicnode.com", { retryCount: 0 }),
      http("https://gnosis.drpc.org", { retryCount: 0 }),
      http("https://gnosis.oat.farm", { retryCount: 0 }),
      http("https://gnosis.api.onfinality.io/public", { retryCount: 0 }),
      http("https://xdai.fairdatasociety.org", { retryCount: 0 }),
    ],
  },
  [sepolia.id]: { chain: sepolia, fallbacks: [] },
};

function buildClients(env: Env): {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  chain: Chain;
} {
  const config = CHAINS[Number(env.CHAIN_ID)];
  if (!config) throw new Error(`unsupported CHAIN_ID: ${env.CHAIN_ID}`);
  const chain: Chain = {
    ...config.chain,
    rpcUrls: { default: { http: [env.RPC_URL] } },
  };

  // Only the primary transport depends on the runtime RPC_URL binding.
  const primary = /^wss?:\/\//.test(env.RPC_URL)
    ? webSocket(env.RPC_URL, { retryCount: 0 })
    : http(env.RPC_URL, { retryCount: 0 });
  const transport = config.fallbacks.length
    ? fallback([primary, ...config.fallbacks], {
        retryCount: 2,
        rank: { interval: 60_000, sampleCount: 5 },
      })
    : primary;

  const account = privateKeyToAccount(env.PRIVATE_KEY as Hex);
  return {
    publicClient: createPublicClient({ chain, transport }),
    walletClient: createWalletClient({ chain, transport, account }),
    account,
    chain,
  };
}

// Inferred straight from the ABI — getActiveVolumes returns VolumeView[].
type VolumeView = ReadContractReturnType<
  typeof registryAbi,
  "getActiveVolumes"
>[number];

/**
 * Page through getActiveVolumes to collect every Active volume. One read for
 * getActiveVolumeCount, then all pages fetched in a single multicall.
 */
async function collectActiveVolumes(
  client: PublicClient,
  registry: `0x${string}`,
  pageSize: number,
): Promise<{ volumes: VolumeView[]; pages: number }> {
  const total = Number(
    await client.readContract({
      address: registry,
      abi: registryAbi,
      functionName: "getActiveVolumeCount",
    }),
  );
  if (total === 0) return { volumes: [], pages: 0 };

  const pageCount = Math.ceil(total / pageSize);
  const pages = await client.multicall({
    allowFailure: false,
    contracts: Array.from({ length: pageCount }, (_, i) => ({
      address: registry,
      abi: registryAbi,
      functionName: "getActiveVolumes" as const,
      args: [BigInt(i * pageSize), BigInt(pageSize)] as const,
    })),
  });
  const volumes = pages.flat();
  return { volumes, pages: pageCount };
}

interface FilterResult {
  due: VolumeView[];
  dead: VolumeView[];
}

/**
 * Client-side triage. The contract is the source of truth (retire/skip edges
 * are re-checked on-chain during trigger), so false positives here are
 * harmless. A volume is "dead" if its batch is missing/expired/mismatched, and
 * "due" if it's active and its remaining per-chunk balance is below target.
 */
async function filterVolumes(
  client: PublicClient,
  postage: `0x${string}`,
  registry: `0x${string}`,
  volumes: VolumeView[],
): Promise<FilterResult> {
  if (volumes.length === 0) return { due: [], dead: [] };

  // Scalars and per-volume batch reads are split into two homogeneous
  // multicalls so viem can infer each result type without casts.
  const [lastPrice, graceBlocks, out] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: postage, abi: postageAbi, functionName: "lastPrice" },
      { address: registry, abi: registryAbi, functionName: "graceBlocks" },
      { address: postage, abi: postageAbi, functionName: "currentTotalOutPayment" },
    ],
  });
  const batches = await client.multicall({
    allowFailure: false,
    contracts: volumes.map((v) => ({
      address: postage,
      abi: postageAbi,
      functionName: "batches" as const,
      args: [v.volumeId] as const,
    })),
  });

  const target = lastPrice * graceBlocks;
  const due: VolumeView[] = [];
  const dead: VolumeView[] = [];

  volumes.forEach((v, i) => {
    const [owner, depth, , , balance] = batches[i]!;
    const live = owner !== zeroAddress;
    const isDead =
      !live ||
      balance <= out ||
      depth !== v.depth ||
      owner.toLowerCase() !== v.chunkSigner.toLowerCase();

    if (isDead) dead.push(v);
    else if (v.accountActive && balance - out < target) due.push(v);
  });

  return { due, dead };
}

/**
 * One cycle: page getActiveVolumes, triage into due/dead, and if anything
 * needs action send trigger(ids[]). Never throws — all errors are captured
 * into RunResult so the scheduled handler won't retry-storm.
 */
export async function runCycle(env: Env): Promise<RunResult> {
  const started = Date.now();
  const pageSize = env.PAGE_SIZE ? Number(env.PAGE_SIZE) : 100;
  const registry = env.REGISTRY_ADDRESS;
  const postage = env.POSTAGE_ADDRESS;

  // Run the cycle and stamp durationMs once, regardless of how it returns.
  // Never throws — errors collapse into an { ok: false } result.
  const run = async (): Promise<Omit<RunResult, "durationMs">> => {
    const { publicClient, walletClient, account, chain } = buildClients(env);

    const { volumes, pages } = await collectActiveVolumes(publicClient, registry, pageSize);
    const base = { ok: true, activeCount: volumes.length, pagesRead: pages };
    if (volumes.length === 0) return { ...base, skipped: "no active volumes" };

    const { due, dead } = await filterVolumes(publicClient, postage, registry, volumes);
    const ids = [...due, ...dead].map((v) => v.volumeId);
    const counts = { ...base, dueCount: due.length, deadCount: dead.length };
    if (ids.length === 0) return { ...counts, skipped: "no due or dead volumes" };

    const { request } = await publicClient.simulateContract({
      address: registry,
      abi: registryAbi,
      functionName: "trigger",
      args: [ids],
      account,
      chain,
    });
    // Gas budget: 300k base + 250k per id, capped at 15M.
    const gasBudget = 300_000n + 250_000n * BigInt(ids.length);
    const hash = await walletClient.writeContract({
      ...request,
      gas: gasBudget < 15_000_000n ? gasBudget : 15_000_000n,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
    return {
      ...counts,
      ok: receipt.status === "success",
      txHash: hash,
      blockNumber: receipt.blockNumber.toString(),
      gasUsed: receipt.gasUsed.toString(),
    };
  };

  const result = await run().catch((err) => ({
    ok: false,
    error: err instanceof Error ? err.message : String(err),
  }));
  return { ...result, durationMs: Date.now() - started };
}
