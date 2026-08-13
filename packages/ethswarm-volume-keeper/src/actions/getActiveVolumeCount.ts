import type { Account, Address, Chain, Client, Transport } from "viem";
import { readContract } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";

export type GetActiveVolumeCountParameters = {
  registry: Address;
  blockNumber?: bigint;
};

export type GetActiveVolumeCountReturnType = bigint;

/**
 * How many volumes are in the registry's active index.
 *
 * @example
 * const count = await getActiveVolumeCount(client, { registry: '0x…' })
 */
export async function getActiveVolumeCount<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetActiveVolumeCountParameters,
): Promise<GetActiveVolumeCountReturnType> {
  return getAction(
    client,
    readContract,
    "readContract",
  )({
    address: parameters.registry,
    abi: registryAbi,
    functionName: "getActiveVolumeCount",
    blockNumber: parameters.blockNumber,
  });
}
