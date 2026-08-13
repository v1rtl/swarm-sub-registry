import type { Account, Address, Chain, Client, Transport } from "viem";
import { multicall } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";
import type { RegistryConfig } from "../types.js";

export type GetRegistryConfigParameters = {
  registry: Address;
  blockNumber?: bigint;
};

export type GetRegistryConfigReturnType = RegistryConfig;

/**
 * Read the registry's immutable wiring: the PostageStamp it tops up and the
 * `graceBlocks` runway it targets.
 *
 * Both are set at construction and cannot change, which is why the PostageStamp
 * address should be discovered here rather than configured by hand.
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { gnosis } from 'viem/chains'
 * import { getRegistryConfig } from 'ethswarm-volume-keeper'
 *
 * const client = createPublicClient({ chain: gnosis, transport: http() })
 * const { postage, graceBlocks } = await getRegistryConfig(client, {
 *   registry: '0x…',
 * })
 */
export async function getRegistryConfig<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetRegistryConfigParameters,
): Promise<GetRegistryConfigReturnType> {
  const { registry, blockNumber } = parameters;

  const [postage, graceBlocks] = await getAction(
    client,
    multicall,
    "multicall",
  )({
    allowFailure: false,
    blockNumber,
    contracts: [
      { address: registry, abi: registryAbi, functionName: "postage" },
      { address: registry, abi: registryAbi, functionName: "graceBlocks" },
    ],
  });

  return { postage, graceBlocks };
}
