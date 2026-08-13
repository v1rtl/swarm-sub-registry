import type { Account, Address, Chain, Client, Transport } from "viem";
import { multicall } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";
import type { VolumeView } from "../types.js";
import { getActiveVolumeCount } from "./getActiveVolumeCount.js";

export type CollectActiveVolumesParameters = {
  registry: Address;
  /** Volumes per page. Default 100. */
  pageSize?: number;
  /** Pin every page to one block. Strongly recommended — see below. */
  blockNumber?: bigint;
};

export type CollectActiveVolumesReturnType = VolumeView[];

/**
 * The registry's entire active index, paged through Multicall3.
 *
 * Pass `blockNumber`. The active index is a swap-and-pop array: `_retire`
 * moves the last element into the retiring volume's slot, so indices shift
 * mid-enumeration. Pages read at different block heights can silently skip a
 * volume that moved into a slot you have already passed.
 *
 * @example
 * const block = await client.getBlock()
 * const volumes = await collectActiveVolumes(client, {
 *   registry: '0x…',
 *   blockNumber: block.number,
 * })
 */
export async function collectActiveVolumes<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: CollectActiveVolumesParameters,
): Promise<CollectActiveVolumesReturnType> {
  const { registry, pageSize = 100, blockNumber } = parameters;
  if (pageSize < 1) throw new Error(`pageSize must be >= 1, got ${pageSize}`);

  const total = await getActiveVolumeCount(client, { registry, blockNumber });
  if (total === 0n) return [];

  const pageCount = Math.ceil(Number(total) / pageSize);
  const pages = await getAction(
    client,
    multicall,
    "multicall",
  )({
    allowFailure: false,
    blockNumber,
    contracts: Array.from({ length: pageCount }, (_, i) => ({
      address: registry,
      abi: registryAbi,
      functionName: "getActiveVolumes" as const,
      args: [BigInt(i * pageSize), BigInt(pageSize)] as const,
    })),
  });

  return pages.flat();
}
