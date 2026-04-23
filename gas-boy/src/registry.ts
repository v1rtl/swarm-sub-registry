import {
  createPublicClient,
  createWalletClient,
  http,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Account,
} from "viem";
import { sepolia, foundry } from "viem/chains";
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

// Canonical Multicall3 address. orion injects this at anvil setup via
// anvil_setCode; live Sepolia ships it natively.
const MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

function buildChain(env: Env): Chain {
  const id = Number(env.CHAIN_ID);
  const base = id === 11155111 ? sepolia : id === 31337 ? foundry : null;
  if (!base) throw new Error(`unsupported CHAIN_ID: ${env.CHAIN_ID}`);
  return {
    ...base,
    rpcUrls: { default: { http: [env.RPC_URL] } },
    contracts: {
      ...base.contracts,
      multicall3: { address: MULTICALL3_ADDRESS },
    },
  };
}

function buildClients(env: Env): {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  chain: Chain;
} {
  const chain = buildChain(env);
  const transport = http(env.RPC_URL);
  const publicClient = createPublicClient({ chain, transport });
  const account = privateKeyToAccount(env.PRIVATE_KEY as Hex);
  const walletClient = createWalletClient({ chain, transport, account });
  return { publicClient, walletClient, account, chain };
}

interface VolumeView {
  volumeId: `0x${string}`;
  owner: `0x${string}`;
  payer: `0x${string}`;
  chunkSigner: `0x${string}`;
  createdAt: bigint;
  ttlExpiry: bigint;
  depth: number;
  status: number;
  accountActive: boolean;
}

/**
 * Diagnostic: assert Multicall3 bytecode is present. Returns error
 * message if missing; undefined if OK. Callers log and skip the cycle
 * on failure — multicall-returning-zeros is a silent footgun.
 */
async function assertMulticall3(client: PublicClient): Promise<string | undefined> {
  const code = await client.getCode({ address: MULTICALL3_ADDRESS });
  if (!code || code === "0x") {
    return `Multicall3 missing at ${MULTICALL3_ADDRESS} — orion must inject it via anvil_setCode`;
  }
  return undefined;
}

/**
 * Page through getActiveVolumes to collect every Active volume. One
 * multicall for getActiveVolumeCount + ceil(n/PAGE) multicalls for pages.
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
  const pagePromises = Array.from({ length: pageCount }, (_, i) =>
    client.readContract({
      address: registry,
      abi: registryAbi,
      functionName: "getActiveVolumes",
      args: [BigInt(i * pageSize), BigInt(pageSize)],
    }),
  );
  const pages = await Promise.all(pagePromises);
  const volumes = pages.flat() as unknown as VolumeView[];
  return { volumes, pages: pageCount };
}

/**
 * Client-side filter: which volumes are likely to benefit from a
 * trigger tx? We proposals all volumes whose batch is observed to be
 * below the registry's topup target. The contract itself is the source
 * of truth — retire/skip edges are evaluated on-chain during trigger —
 * so false positives here are harmless (emit Toppedup with amount=0 is
 * impossible; the contract returns silently).
 *
 * A volume is marked "due" iff:
 *   - status == Active, AND
 *   - accountActive (else trigger would just emit TopupSkipped(NoAuth)
 *     and burn gas for nothing), AND
 *   - PostageStamp reports a live batch (owner != 0 and not expired),
 *     AND the remaining per-chunk < target per-chunk.
 */
interface FilterResult {
  due: VolumeView[];
  dead: VolumeView[];
}

async function filterVolumes(
  client: PublicClient,
  postage: `0x${string}`,
  registry: `0x${string}`,
  volumes: VolumeView[],
): Promise<FilterResult> {
  if (volumes.length === 0) return { due: [], dead: [] };

  // One multicall: [lastPrice, graceBlocks, currentTotalOutPayment, ...batches(id)]
  const base = [
    {
      address: postage,
      abi: postageAbi,
      functionName: "lastPrice",
    } as const,
    {
      address: registry,
      abi: registryAbi,
      functionName: "graceBlocks",
    } as const,
    {
      address: postage,
      abi: postageAbi,
      functionName: "currentTotalOutPayment",
    } as const,
  ];
  const batchReads = volumes.map(
    (v) =>
      ({
        address: postage,
        abi: postageAbi,
        functionName: "batches",
        args: [v.volumeId],
      }) as const,
  );

  const results = await client.multicall({
    contracts: [...base, ...batchReads],
    allowFailure: false,
  });

  const lastPrice = results[0] as unknown as bigint;
  const graceBlocks = results[1] as unknown as bigint;
  const outpayment = results[2] as unknown as bigint;
  const target = lastPrice * graceBlocks;

  const due: VolumeView[] = [];
  const dead: VolumeView[] = [];
  for (let i = 0; i < volumes.length; ++i) {
    const v = volumes[i]!;
    const batch = results[3 + i] as unknown as readonly [
      `0x${string}`,
      number,
      number,
      boolean,
      bigint,
      bigint,
    ];
    const batchOwner = batch[0];
    const batchDepth = batch[1];
    const normalisedBalance = batch[4];

    // Dead: batch missing, expired, depth/owner mismatch → trigger will retire.
    const batchMissing = batchOwner === "0x0000000000000000000000000000000000000000";
    const batchExpired = !batchMissing && normalisedBalance <= outpayment;
    const depthMismatch = !batchMissing && batchDepth !== v.depth;
    const ownerMismatch = !batchMissing && batchOwner.toLowerCase() !== v.chunkSigner.toLowerCase();

    if (batchMissing || batchExpired || depthMismatch || ownerMismatch) {
      dead.push(v);
      continue;
    }

    // Due: needs topup (only if account is active, else trigger just emits skip).
    if (!v.accountActive) continue;
    const remaining = normalisedBalance - outpayment;
    if (remaining < target) due.push(v);
  }
  return { due, dead };
}

/**
 * The core of gas-boy. One cycle:
 *   1. assert Multicall3 present (else skip with explicit log).
 *   2. page getActiveVolumes → VolumeView[].
 *   3. client-side filter → due ids.
 *   4. if due is non-empty: send trigger(ids[]).
 *
 * Never throws — all errors captured into RunResult so the scheduled
 * handler can log them without retry storms.
 */
export async function runCycle(env: Env): Promise<RunResult> {
  const started = Date.now();
  const duration = () => Date.now() - started;
  const pageSize = env.PAGE_SIZE ? Number(env.PAGE_SIZE) : 100;

  let publicClient: PublicClient;
  let walletClient: WalletClient;
  let account: Account;
  let chain: Chain;
  try {
    ({ publicClient, walletClient, account, chain } = buildClients(env));
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
      durationMs: duration(),
    };
  }

  const multicallErr = await assertMulticall3(publicClient);
  if (multicallErr) {
    return { ok: false, error: multicallErr, durationMs: duration() };
  }

  const result: RunResult = { ok: true, durationMs: 0 };
  const registry = env.REGISTRY_ADDRESS;
  const postage = env.POSTAGE_ADDRESS;

  let triggerIds: `0x${string}`[] = [];
  try {
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
    triggerIds = [...due, ...dead].map((v) => v.volumeId);
  } catch (err) {
    result.ok = false;
    result.error = err instanceof Error ? err.message : String(err);
    result.durationMs = duration();
    return result;
  }

  if (triggerIds.length === 0) {
    result.skipped = "no due or dead volumes";
    result.durationMs = duration();
    return result;
  }

  try {
    const ids = triggerIds;
    const { request } = await publicClient.simulateContract({
      address: registry,
      abi: registryAbi,
      functionName: "trigger",
      args: [ids],
      account,
      chain,
    });
    // Gas budget: 300k base + 250k per due id, capped at 15M.
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
    if (receipt.status !== "success") result.ok = false;
  } catch (err) {
    result.ok = false;
    result.error = err instanceof Error ? err.message : String(err);
  }

  result.durationMs = duration();
  return result;
}
