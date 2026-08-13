import type { Account, Address, Chain, Client, Hex, Transport } from "viem";
import { simulateContract, writeContract } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";

export type ReapParameters = {
  registry: Address;
  volumeId: Hex;
  /** Defaults to the client's account. */
  account?: Account | Address;
  chain?: Chain | null;
};

export type ReapReturnType = Hex;

/**
 * Retire a single volume whose TTL has passed, detaching it from the active
 * index. A no-op on an already-retired volume.
 *
 * Rarely needed: `trigger` reaps the volumes it touches. This exists for
 * manual cleanup.
 *
 * @example
 * const hash = await reap(walletClient, { registry: '0x…', volumeId: '0x…' })
 */
export async function reap<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: ReapParameters,
): Promise<ReapReturnType> {
  const {
    registry,
    volumeId,
    account = client.account,
    chain = client.chain,
  } = parameters;

  const { request } = await getAction(
    client,
    simulateContract,
    "simulateContract",
  )({
    address: registry,
    abi: registryAbi,
    functionName: "reap",
    args: [volumeId],
    account,
    chain,
  } as never);

  return getAction(client, writeContract, "writeContract")(request as never);
}
