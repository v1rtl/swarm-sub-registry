import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Account,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { registryAbi } from "./abi";

export interface Env {
  RPC_URL: string;
  CHAIN_ID: string;
  REGISTRY_ADDRESS: `0x${string}`;
  PRIVATE_KEY: string;
}

export interface RunResult {
  ok: boolean;
  skipped?: string;
  dueCount?: number;
  totalSubs?: number;
  txHash?: Hex;
  blockNumber?: string; // bigint-as-string for JSON-safe logs
  gasUsed?: string;
  error?: string;
  durationMs: number;
}

function buildChain(env: Env): Chain {
  const id = Number(env.CHAIN_ID);
  return defineChain({
    id,
    name: `chain-${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [env.RPC_URL] } },
  });
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

/**
 * Read all batchIds via subscriptionCount + indexed reads, then check
 * isDue for each. Returns the set of due batch ids. Used to avoid sending
 * a no-op keepalive tx when nothing is due.
 */
async function collectDueBatches(
  publicClient: PublicClient,
  registry: `0x${string}`,
): Promise<{ total: number; due: Hex[] }> {
  const count = (await publicClient.readContract({
    address: registry,
    abi: registryAbi,
    functionName: "subscriptionCount",
  })) as bigint;

  const total = Number(count);
  if (total === 0) return { total: 0, due: [] };

  // Read all batchIds in parallel.
  const ids = (await Promise.all(
    Array.from({ length: total }, (_, i) =>
      publicClient.readContract({
        address: registry,
        abi: registryAbi,
        functionName: "batchIds",
        args: [BigInt(i)],
      }),
    ),
  )) as Hex[];

  // Check isDue in parallel.
  const dueFlags = (await Promise.all(
    ids.map((id) =>
      publicClient.readContract({
        address: registry,
        abi: registryAbi,
        functionName: "isDue",
        args: [id],
      }),
    ),
  )) as boolean[];

  const due = ids.filter((_, i) => dueFlags[i]);
  return { total, due };
}

/**
 * The core of gas-boy. Checks if any subscription is due; if so, sends
 * a single `keepalive()` tx and waits for the receipt.
 *
 * Never throws. All failures are captured into RunResult.error so the
 * scheduled handler can log them without crashing.
 */
export async function runKeepalive(env: Env): Promise<RunResult> {
  const started = Date.now();
  const duration = () => Date.now() - started;

  try {
    const { publicClient, walletClient, account, chain } = buildClients(env);
    const registry = env.REGISTRY_ADDRESS;

    const { total, due } = await collectDueBatches(publicClient, registry);

    if (due.length === 0) {
      return {
        ok: true,
        skipped: "no subscriptions due",
        totalSubs: total,
        dueCount: 0,
        durationMs: duration(),
      };
    }

    // Simulate to catch obvious reverts. The gas estimate simulation
    // returns is tight — PostageStamp's order-stats tree ops can consume
    // substantially more than the simulated path, so we add generous
    // headroom proportional to the number of due batches.
    const { request } = await publicClient.simulateContract({
      address: registry,
      abi: registryAbi,
      functionName: "keepalive",
      account,
      chain,
    });

    // Budget: 500k base + 400k per due batch. Cap at 15M (anvil default
    // block gas limit is 30M; mainnets ~30M). This comfortably covers
    // PostageStamp.topUp's tree rebalancing across realistic fleet sizes.
    const gasBudget = 500_000n + 400_000n * BigInt(due.length);
    const requestWithGas = { ...request, gas: gasBudget < 15_000_000n ? gasBudget : 15_000_000n };

    const hash = await walletClient.writeContract(requestWithGas);
    const receipt = await publicClient.waitForTransactionReceipt({
      hash,
      timeout: 60_000,
    });

    return {
      ok: receipt.status === "success",
      totalSubs: total,
      dueCount: due.length,
      txHash: hash,
      blockNumber: receipt.blockNumber.toString(),
      gasUsed: receipt.gasUsed.toString(),
      durationMs: duration(),
    };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
      durationMs: duration(),
    };
  }
}
