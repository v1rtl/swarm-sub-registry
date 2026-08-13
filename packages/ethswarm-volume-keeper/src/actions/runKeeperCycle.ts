import type {
  Account,
  Address,
  Chain,
  Client,
  Hex,
  Transport,
} from "viem";
import { simulateContract, waitForTransactionReceipt } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";
import { decodeCycleEvents } from "../events.js";
import { chunk } from "../triage.js";
import type {
  KeeperMode,
  RegistryConfig,
  TxResult,
  VolumeOutcome,
} from "../types.js";
import { getKeeperPlan } from "./getKeeperPlan.js";
import { trigger } from "./trigger.js";

export type RunKeeperCycleParameters = {
  registry: Address;
  /** Default `{ type: 'all' }`. */
  mode?: KeeperMode;
  /** Volumes per page in `all` mode. Default 100. */
  pageSize?: number;
  /** Skip the immutables read by supplying them (they never change). */
  registryConfig?: RegistryConfig;
  /** Volume ids per transaction. Default 50. */
  maxIdsPerTx?: number;
  /** Transactions per cycle. Default 8; the rest defers to the next cycle. */
  maxTxPerCycle?: number;
  /** Headroom over the gas estimate. Default 1.2 — see {@link trigger}. */
  gasMultiplier?: number;
  /** Default 1. */
  confirmations?: number;
  /** Per-transaction receipt wait, in ms. Default 60_000. */
  receiptTimeout?: number;
  /** Soft deadline in ms; no *new* transaction starts past it. Default 120_000. */
  cycleTimeout?: number;
  /** Simulate everything, send nothing. */
  dryRun?: boolean;
  account?: Account | Address;
  chain?: Chain | null;
};

export type RunKeeperCycleReturnType = {
  /** False if anything failed. The cycle still ran to completion. */
  ok: boolean;
  mode: KeeperMode["type"];
  /** The block every read was pinned to. */
  blockNumber?: bigint;
  /**
   * The registry's immutables as read this cycle. Feed it back in as
   * `registryConfig` next time to skip that read — they cannot change.
   */
  registryConfig?: RegistryConfig;
  volumeCount: number;
  dueCount: number;
  deadCount: number;
  /** Active, funded, nothing to do. */
  healthyCount: number;
  /** Underfunded with no active payer account — reported, never sent. */
  noAuthCount: number;
  /** Set when the cycle deliberately did no work. */
  skipped?: string;
  txs: TxResult[];
  /** Decoded from receipts — what actually happened on chain. */
  toppedUp: Array<{ volumeId: Hex; amount: bigint }>;
  retired: VolumeOutcome[];
  /** Volumes the contract declined to fund, with its own reason. */
  topupSkipped: VolumeOutcome[];
  /** `selected` mode: requested ids that are not Active volumes. */
  notActive: Hex[];
  warnings: string[];
  error?: string;
  durationMs: number;
};

const message = (err: unknown): string =>
  err instanceof Error ? err.message : String(err);

/**
 * One full keeper cycle: read the registry, work out what needs topping up,
 * and send it.
 *
 * **Never throws.** Every failure is folded into the returned result, because
 * throwing out of a cron handler causes retry storms. Check `ok`.
 *
 * Stateless and self-healing: nothing is remembered between cycles. If a
 * transaction does not mine, the result reports it (with its hash) and the next
 * cycle re-reads the chain and decides again. `trigger` is idempotent, so a
 * late-mining transaction tops up zero. That also makes it safe to run two
 * keepers concurrently for redundancy.
 *
 * The client must be able to both read and write — a wallet client extended
 * with `publicActions`, or any client with an account attached.
 *
 * @example
 * import { createWalletClient, http, publicActions } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { gnosis } from 'viem/chains'
 * import { runKeeperCycle } from 'ethswarm-volume-keeper'
 *
 * const client = createWalletClient({
 *   account: privateKeyToAccount('0x…'),
 *   chain: gnosis,
 *   transport: http(),
 * }).extend(publicActions)
 *
 * const result = await runKeeperCycle(client, { registry: '0x…' })
 */
export async function runKeeperCycle<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: RunKeeperCycleParameters,
): Promise<RunKeeperCycleReturnType> {
  const {
    registry,
    mode = { type: "all" },
    maxIdsPerTx = 50,
    maxTxPerCycle = 8,
    confirmations = 1,
    receiptTimeout = 60_000,
    cycleTimeout = 120_000,
    dryRun = false,
    account = client.account,
    chain = client.chain,
  } = parameters;

  const startedAt = Date.now();
  const result: RunKeeperCycleReturnType = {
    ok: true,
    mode: mode.type,
    volumeCount: 0,
    dueCount: 0,
    deadCount: 0,
    healthyCount: 0,
    noAuthCount: 0,
    txs: [],
    toppedUp: [],
    retired: [],
    topupSkipped: [],
    notActive: [],
    warnings: [],
    durationMs: 0,
  };

  try {
    const plan = await getKeeperPlan(client, {
      registry,
      mode,
      pageSize: parameters.pageSize,
      registryConfig: parameters.registryConfig,
    });

    result.blockNumber = plan.blockNumber;
    result.registryConfig = plan.registryConfig;
    result.volumeCount = plan.volumes.length;
    result.dueCount = plan.due.length;
    result.deadCount = plan.dead.length;
    result.healthyCount = plan.healthy.length;
    result.noAuthCount = plan.noAuth.length;
    result.notActive = plan.notActive;

    if (plan.volumes.length === 0) {
      result.skipped = "no active volumes";
      return result;
    }
    if (plan.volumeIds.length === 0) {
      result.skipped = "nothing due or dead";
      return result;
    }

    const chunks = chunk(plan.volumeIds, maxIdsPerTx);
    if (chunks.length > maxTxPerCycle) {
      const deferred = chunks.slice(maxTxPerCycle).flat().length;
      result.warnings.push(
        `maxTxPerCycle (${maxTxPerCycle}) reached: ${deferred} volume(s) deferred to the next cycle`,
      );
    }

    const deadline = startedAt + cycleTimeout;
    for (const [i, volumeIds] of chunks.slice(0, maxTxPerCycle).entries()) {
      if (i > 0 && Date.now() > deadline) {
        result.warnings.push(
          `cycle deadline reached after ${i} transaction(s); remaining volumes deferred`,
        );
        break;
      }

      const tx = await sendChunk(volumeIds);
      result.txs.push(tx);
      if (tx.status === "failed" || tx.status === "reverted") result.ok = false;
    }
  } catch (err) {
    result.ok = false;
    result.error = message(err);
  }

  result.durationMs = Date.now() - startedAt;
  return result;

  async function sendChunk(volumeIds: Hex[]): Promise<TxResult> {
    let hash: Hex | undefined;
    try {
      if (dryRun) {
        await getAction(
          client,
          simulateContract,
          "simulateContract",
        )({
          address: registry,
          abi: registryAbi,
          functionName: "trigger",
          args: [volumeIds],
          account,
          chain,
        } as never);
        return { volumeIds, status: "simulated" };
      }

      hash = await trigger(client, {
        registry,
        volumeIds,
        account,
        chain,
        gasMultiplier: parameters.gasMultiplier,
      } as never);

      const receipt = await getAction(
        client,
        waitForTransactionReceipt,
        "waitForTransactionReceipt",
      )({ hash, confirmations, timeout: receiptTimeout });

      const events = decodeCycleEvents(receipt.logs, registry);
      result.toppedUp.push(...events.toppedUp);
      result.retired.push(...events.retired);
      result.topupSkipped.push(...events.topupSkipped);

      return {
        volumeIds,
        status: receipt.status === "success" ? "success" : "reverted",
        hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed,
      };
    } catch (err) {
      // A sent-but-unconfirmed transaction still reports its hash so it can be
      // followed up; the next cycle re-decides from chain state regardless.
      return {
        volumeIds,
        status: "failed",
        ...(hash ? { hash } : {}),
        error: message(err),
      };
    }
  }
}
