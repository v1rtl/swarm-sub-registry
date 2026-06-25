import {
  createPublicClient,
  createWalletClient,
  http,
  webSocket,
  fallback,
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
// Multicall3 deployment, so there's nothing to inject.
const CHAINS: Record<number, Chain> = {
  [gnosis.id]: gnosis,
  [sepolia.id]: sepolia,
};

// Free public Gnosis-mainnet RPCs used as automatic fallbacks behind the
// configured env.RPC_URL. viem's `fallback` rotates to the next endpoint on
// error and re-ranks by latency, so one throttled provider can't stall a cycle.
const GNOSIS_FALLBACK_RPCS = [
  "https://gnosis-rpc.publicnode.com",
  "wss://gnosis-rpc.publicnode.com",
  "https://gnosis.drpc.org",
  "https://gnosis.oat.farm",
  "https://gnosis.api.onfinality.io/public",
  "https://xdai.fairdatasociety.org",
];

const transportFor = (url: string): Transport =>
  /^wss?:\/\//.test(url)
    ? webSocket(url, { key: url, retryCount: 0 })
    : http(url, { key: url, retryCount: 0 });

function buildClients(env: Env): {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  chain: Chain;
} {
  const id = Number(env.CHAIN_ID);
  const base = CHAINS[id];
  if (!base) throw new Error(`unsupported CHAIN_ID: ${env.CHAIN_ID}`);
  const chain: Chain = {
    ...base,
    rpcUrls: { default: { http: [env.RPC_URL] } },
  };

  const urls = [
    env.RPC_URL,
    ...(id === gnosis.id ? GNOSIS_FALLBACK_RPCS : []),
  ].filter((u, i, a) => u && a.indexOf(u) === i);
  const transports = urls.map(transportFor);
  const transport =
    transports.length === 1
      ? transports[0]!
      : fallback(transports, {
          retryCount: 2,
          rank: { interval: 60_000, sampleCount: 5 },
        });

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
  const zeroAddr = "0x0000000000000000000000000000000000000000";

  const due: VolumeView[] = [];
  const dead: VolumeView[] = [];
  for (let i = 0; i < volumes.length; ++i) {
    const v = volumes[i]!;
    const [owner, depth, , , normalisedBalance] = batches[i]!;

    const missing = owner === zeroAddr;
    const expired = !missing && normalisedBalance <= out;
    const depthMismatch = !missing && depth !== v.depth;
    const ownerMismatch =
      !missing && owner.toLowerCase() !== v.chunkSigner.toLowerCase();

    if (missing || expired || depthMismatch || ownerMismatch) {
      dead.push(v);
    } else if (v.accountActive && normalisedBalance - out < target) {
      due.push(v);
    }
  }
  return { due, dead };
}

/**
 * One cycle: page getActiveVolumes, triage into due/dead, and if anything
 * needs action send trigger(ids[]). Never throws — all errors are captured
 * into RunResult so the scheduled handler won't retry-storm.
 */
export async function runCycle(env: Env): Promise<RunResult> {
  const started = Date.now();
  const duration = () => Date.now() - started;
  const pageSize = env.PAGE_SIZE ? Number(env.PAGE_SIZE) : 100;
  const registry = env.REGISTRY_ADDRESS;
  const postage = env.POSTAGE_ADDRESS;

  try {
    const { publicClient, walletClient, account, chain } = buildClients(env);
    const result: RunResult = { ok: true, durationMs: 0 };

    const { volumes, pages } = await collectActiveVolumes(
      publicClient,
      registry,
      pageSize,
    );
    result.activeCount = volumes.length;
    result.pagesRead = pages;
    if (volumes.length === 0) {
      result.skipped = "no active volumes";
      result.durationMs = duration();
      return result;
    }

    const { due, dead } = await filterVolumes(publicClient, postage, registry, volumes);
    result.dueCount = due.length;
    result.deadCount = dead.length;
    const ids = [...due, ...dead].map((v) => v.volumeId);
    if (ids.length === 0) {
      result.skipped = "no due or dead volumes";
      result.durationMs = duration();
      return result;
    }

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
    const receipt = await publicClient.waitForTransactionReceipt({
      hash,
      timeout: 60_000,
    });
    result.txHash = hash;
    result.blockNumber = receipt.blockNumber.toString();
    result.gasUsed = receipt.gasUsed.toString();
    result.ok = receipt.status === "success";
    result.durationMs = duration();
    return result;
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
      durationMs: duration(),
    };
  }
}
