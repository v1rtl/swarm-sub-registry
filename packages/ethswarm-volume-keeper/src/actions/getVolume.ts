import type { Account, Address, Chain, Client, Hex, Transport } from "viem";
import { readContract } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";
import type { VolumeView } from "../types.js";

export type GetVolumeParameters = {
  registry: Address;
  volumeId: Hex;
  blockNumber?: bigint;
};

export type GetVolumeReturnType = VolumeView;

/**
 * A single volume by id. An unknown id comes back zeroed with `status: 0`
 * rather than reverting.
 *
 * @example
 * const volume = await getVolume(client, { registry: '0x…', volumeId: '0x…' })
 */
export async function getVolume<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetVolumeParameters,
): Promise<GetVolumeReturnType> {
  return getAction(
    client,
    readContract,
    "readContract",
  )({
    address: parameters.registry,
    abi: registryAbi,
    functionName: "getVolume",
    args: [parameters.volumeId],
    blockNumber: parameters.blockNumber,
  });
}
