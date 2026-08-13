import type { Account, Address, Chain, Client, Hex, Transport } from "viem";
import { multicall } from "viem/actions";
import { getAction } from "viem/utils";
import { postageAbi } from "../abi.js";
import type { BatchState } from "../triage.js";

export type GetBatchStatesParameters = {
  postage: Address;
  volumeIds: readonly Hex[];
  blockNumber?: bigint;
};

export type GetBatchStatesReturnType = {
  /** Per-chunk, per-block price. */
  lastPrice: bigint;
  /** `currentTotalOutPayment` — subtract to get a batch's remaining runway. */
  outPayment: bigint;
  /** Aligned with the `volumeIds` passed in. */
  batches: BatchState[];
};

/**
 * PostageStamp state for a set of volumes: the two chain-wide scalars plus one
 * batch record per id, in the order given.
 *
 * Feed the result to {@link triage} to classify what needs doing.
 *
 * @example
 * const state = await getBatchStates(client, {
 *   postage: '0x…',
 *   volumeIds: volumes.map((v) => v.volumeId),
 *   blockNumber: block.number,
 * })
 */
export async function getBatchStates<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: GetBatchStatesParameters,
): Promise<GetBatchStatesReturnType> {
  const { postage, volumeIds, blockNumber } = parameters;

  // Two homogeneous multicalls rather than one mixed batch, so viem infers
  // each result shape without casts.
  const [lastPrice, outPayment] = await getAction(
    client,
    multicall,
    "multicall",
  )({
    allowFailure: false,
    blockNumber,
    contracts: [
      { address: postage, abi: postageAbi, functionName: "lastPrice" },
      { address: postage, abi: postageAbi, functionName: "currentTotalOutPayment" },
    ],
  });

  const raw = await getAction(
    client,
    multicall,
    "multicall",
  )({
    allowFailure: false,
    blockNumber,
    contracts: volumeIds.map((volumeId) => ({
      address: postage,
      abi: postageAbi,
      functionName: "batches" as const,
      args: [volumeId] as const,
    })),
  });

  return {
    lastPrice,
    outPayment,
    batches: raw.map(([owner, depth, , , normalisedBalance]) => ({
      owner,
      depth,
      normalisedBalance,
    })),
  };
}
