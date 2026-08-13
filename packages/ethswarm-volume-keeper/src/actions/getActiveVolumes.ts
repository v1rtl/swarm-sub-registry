import type { Account, Address, Chain, Client, Transport } from "viem";
import { readContract } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";
import type { VolumeView } from "../types.js";

export type GetActiveVolumesParameters = {
  registry: Address;
  offset?: bigint;
  limit?: bigint;
  blockNumber?: bigint;
};

export type GetActiveVolumesReturnType = readonly VolumeView[];

/**
 * One page of the registry's active index.
 *
 * To read the whole index, prefer {@link collectActiveVolumes} — it pages in a
 * single multicall against a pinned block. Paging by hand across block heights
 * is unsafe: the active index is a swap-and-pop array, so indices shift the
 * moment a volume retires.
 *
 * @example
 * const page = await getActiveVolumes(client, {
 *   registry: '0x…',
 *   offset: 0n,
 *   limit: 100n,
 * })
 */
export async function getActiveVolumes<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetActiveVolumesParameters,
): Promise<GetActiveVolumesReturnType> {
  const { registry, offset = 0n, limit = 100n, blockNumber } = parameters;

  return getAction(
    client,
    readContract,
    "readContract",
  )({
    address: registry,
    abi: registryAbi,
    functionName: "getActiveVolumes",
    args: [offset, limit],
    blockNumber,
  });
}
