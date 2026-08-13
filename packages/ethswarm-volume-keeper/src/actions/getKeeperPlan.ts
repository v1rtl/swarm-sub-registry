import type { Account, Address, Chain, Client, Hex, Transport } from "viem";
import { getBlock, multicall } from "viem/actions";
import { getAction } from "viem/utils";
import { VOLUME_STATUS, registryAbi } from "../abi.js";
import { triage, triggerIds, type ChainState, type TriageResult } from "../triage.js";
import type { KeeperMode, RegistryConfig, VolumeView } from "../types.js";
import { collectActiveVolumes } from "./collectActiveVolumes.js";
import { getBatchStates } from "./getBatchStates.js";
import { getRegistryConfig } from "./getRegistryConfig.js";

export type GetKeeperPlanParameters = {
  registry: Address;
  /** Default `{ type: 'all' }`. */
  mode?: KeeperMode;
  /** Volumes per page in `all` mode. Default 100. */
  pageSize?: number;
  /** Skip the immutables read by supplying them (they never change). */
  registryConfig?: RegistryConfig;
  /** Pin to a specific block. Default: the current latest block. */
  blockNumber?: bigint;
};

export type GetKeeperPlanReturnType = TriageResult & {
  /** The block every read was pinned to. */
  blockNumber: bigint;
  registryConfig: RegistryConfig;
  chainState: ChainState;
  volumes: VolumeView[];
  /** Ids to pass to `trigger`: top-ups first, cleanup after. */
  volumeIds: Hex[];
  /** `selected` mode: requested ids that are not Active volumes. */
  notActive: Hex[];
};

/**
 * Read-only: work out what a keeper cycle would do, without sending anything.
 *
 * Every read is pinned to one block, so the enumeration and the PostageStamp
 * state it is judged against are a consistent snapshot.
 *
 * Use this to inspect a registry, to build a dashboard, or to apply your own
 * policy on top before calling {@link trigger} yourself. {@link runKeeperCycle}
 * is this plus the sending.
 *
 * @example
 * const plan = await getKeeperPlan(client, { registry: '0x…' })
 * console.log(plan.due.length, plan.dead.length, plan.noAuth.length)
 */
export async function getKeeperPlan<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetKeeperPlanParameters,
): Promise<GetKeeperPlanReturnType> {
  const { registry, mode = { type: "all" }, pageSize } = parameters;

  const block = await getAction(
    client,
    getBlock,
    "getBlock",
  )(
    parameters.blockNumber !== undefined
      ? { blockNumber: parameters.blockNumber }
      : { blockTag: "latest" },
  );
  if (block.number === null) throw new Error("RPC returned a pending block");
  const blockNumber = block.number;

  const registryConfig =
    parameters.registryConfig ??
    (await getRegistryConfig(client, { registry, blockNumber }));

  let volumes: VolumeView[];
  const notActive: Hex[] = [];

  if (mode.type === "selected") {
    const views = await getAction(
      client,
      multicall,
      "multicall",
    )({
      allowFailure: false,
      blockNumber,
      contracts: mode.volumeIds.map((volumeId) => ({
        address: registry,
        abi: registryAbi,
        functionName: "getVolume" as const,
        args: [volumeId] as const,
      })),
    });

    volumes = [];
    views.forEach((view, i) => {
      if (view.status === VOLUME_STATUS.active) volumes.push(view);
      else notActive.push(mode.volumeIds[i]!);
    });
  } else {
    volumes = await collectActiveVolumes(client, {
      registry,
      pageSize,
      blockNumber,
    });
  }

  const { lastPrice, outPayment, batches } = await getBatchStates(client, {
    postage: registryConfig.postage,
    volumeIds: volumes.map((v) => v.volumeId),
    blockNumber,
  });

  const chainState: ChainState = {
    lastPrice,
    outPayment,
    graceBlocks: registryConfig.graceBlocks,
    timestamp: block.timestamp,
  };
  const triaged = triage(volumes, batches, chainState);

  return {
    ...triaged,
    blockNumber,
    registryConfig,
    chainState,
    volumes,
    volumeIds: triggerIds(triaged),
    notActive,
  };
}
