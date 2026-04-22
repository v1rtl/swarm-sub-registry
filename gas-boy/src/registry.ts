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
  totalSubs?: number;
  dueCount?: number;
  deadCount?: number;
  txHash?: Hex;
  blockNumber?: string; // bigint-as-string for JSON-safe logs
  gasUsed?: string;
  error?: string;
  pruneTxHash?: Hex;
  pruneBlockNumber?: string;
  pruneGasUsed?: string;
  pruneError?: string;
  durationMs: number;
}

function buildChain(env: Env): Chain {
  const id = Number(env.CHAIN_ID);
  const base =
    id === 11155111 ? sepolia : id === 31337 ? foundry : null;
  if (!base) throw new Error(`unsupported CHAIN_ID: ${env.CHAIN_ID}`);
  // Override the rpc transport with the env-configured URL while keeping
  // viem's curated chain metadata (multicall3, native currency, etc.).
  return { ...base, rpcUrls: { default: { http: [env.RPC_URL] } } };
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
 * Read all batchIds via volumeCount + a single multicall, then fetch
 * (isDue, isDead) for each id via a second multicall. Constant 3 RPC
 * round-trips regardless of volume count.
 */
async function collectActionable(
  client: PublicClient,
  registry: `0x${string}`,
): Promise<{ total: number; due: `0x${string}`[]; dead: `0x${string}`[] }> {
  const total = Number(
    await client.readContract({
      address: registry,
      abi: registryAbi,
      functionName: "volumeCount",
    }),
  );
  if (total === 0) return { total: 0, due: [], dead: [] };

  // Each contract entry needs `as const` so viem can narrow `functionName`
  // back to the specific abi item; without it, multicall infers a union
  // of every possible output across registryAbi.
  const ids = await client.multicall({
    contracts: Array.from(
      { length: total },
      (_, i) =>
        ({
          address: registry,
          abi: registryAbi,
          functionName: "batchIds",
          args: [BigInt(i)],
        }) as const,
    ),
    allowFailure: false,
  });

  const flags = await client.multicall({
    contracts: ids.flatMap(
      (id) =>
        [
          {
            address: registry,
            abi: registryAbi,
            functionName: "isDue",
            args: [id],
          } as const,
          {
            address: registry,
            abi: registryAbi,
            functionName: "isDead",
            args: [id],
          } as const,
        ] as const,
    ),
    allowFailure: false,
  });

  const due: `0x${string}`[] = [];
  const dead: `0x${string}`[] = [];
  ids.forEach((id, i) => {
    if (flags[2 * i]) due.push(id);
    if (flags[2 * i + 1]) dead.push(id);
  });
  return { total, due, dead };
}

/**
 * The core of gas-boy. Each cron cycle:
 *   1. read all subscriptions, classify due / dead via multicall
 *   2. if any due: send `keepalive()`
 *   3. if any dead: send `pruneDead(dead)`
 *
 * Both txs are independent; either may fail without affecting the other.
 * Never throws — all errors captured into RunResult so the scheduled
 * handler can log them without retry storms.
 */
export async function runKeepalive(env: Env): Promise<RunResult> {
  const started = Date.now();
  const duration = () => Date.now() - started;

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

  const registry = env.REGISTRY_ADDRESS;
  const result: RunResult = { ok: true, durationMs: 0 };

  let due: `0x${string}`[] = [];
  let dead: `0x${string}`[] = [];
  try {
    const collected = await collectActionable(publicClient, registry);
    result.totalSubs = collected.total;
    result.dueCount = collected.due.length;
    result.deadCount = collected.dead.length;
    due = collected.due;
    dead = collected.dead;
  } catch (err) {
    result.ok = false;
    result.error = err instanceof Error ? err.message : String(err);
    result.durationMs = duration();
    return result;
  }

  if (due.length === 0 && dead.length === 0) {
    result.skipped = "no subscriptions actionable";
    result.durationMs = duration();
    return result;
  }

  if (due.length > 0) {
    try {
      const { request } = await publicClient.simulateContract({
        address: registry,
        abi: registryAbi,
        functionName: "keepalive",
        account,
        chain,
      });
      // Budget: 500k base + 400k per due batch, capped at 15M.
      const gasBudget = 500_000n + 400_000n * BigInt(due.length);
      const requestWithGas = {
        ...request,
        gas: gasBudget < 15_000_000n ? gasBudget : 15_000_000n,
      };
      const hash = await walletClient.writeContract(requestWithGas);
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
  }

  if (dead.length > 0) {
    try {
      const { request } = await publicClient.simulateContract({
        address: registry,
        abi: registryAbi,
        functionName: "pruneDead",
        args: [dead],
        account,
        chain,
      });
      // Budget: 100k base + 60k per dead id, capped at 15M.
      const gasBudget = 100_000n + 60_000n * BigInt(dead.length);
      const requestWithGas = {
        ...request,
        gas: gasBudget < 15_000_000n ? gasBudget : 15_000_000n,
      };
      const hash = await walletClient.writeContract(requestWithGas);
      const receipt = await publicClient.waitForTransactionReceipt({
        hash,
        timeout: 60_000,
      });
      result.pruneTxHash = hash;
      result.pruneBlockNumber = receipt.blockNumber.toString();
      result.pruneGasUsed = receipt.gasUsed.toString();
      if (receipt.status !== "success") result.ok = false;
    } catch (err) {
      result.ok = false;
      result.pruneError = err instanceof Error ? err.message : String(err);
    }
  }

  result.durationMs = duration();
  return result;
}
