import type { Account, Address, Chain, Client, Hex, Transport } from "viem";
import { estimateContractGas, writeContract } from "viem/actions";
import { getAction } from "viem/utils";
import { registryAbi } from "../abi.js";

export type TriggerParameters = {
  registry: Address;
  volumeIds: readonly Hex[];
  /** Defaults to the client's account. */
  account?: Account | Address;
  chain?: Chain | null;
  /** Explicit gas limit, skipping estimation entirely. */
  gas?: bigint;
  /** Headroom over the estimate. Default 1.2 — see below for why it matters. */
  gasMultiplier?: number;
};

export type TriggerReturnType = Hex;

const scaleGas = (gas: bigint, multiplier: number): bigint =>
  (gas * BigInt(Math.round(multiplier * 100))) / 100n;

/**
 * Top up (or retire) a batch of volumes.
 *
 * Idempotent: the contract tops up to a target, so a second call in the same
 * block transfers nothing.
 *
 * **Gas matters more here than usual.** `trigger(bytes32[])` runs each id as
 * `try this._triggerExt(id) {} catch {}`, and an inner call only receives
 * 63/64 of the remaining gas. Run short and the inner call runs out, the
 * `catch` swallows it, the loop moves on, and the transaction *succeeds* —
 * having topped up nothing. An under-estimate fails silently rather than
 * reverting, which is why the estimate is scaled rather than used raw.
 *
 * That is also why there is no cap: a ceiling below what the batch needs
 * doesn't fail loudly, it silently drops volumes. Bound the work with
 * `maxIdsPerTx` instead, or pass `gas` if you want an exact limit. Unused gas
 * is refunded, so an over-estimate costs nothing.
 *
 * A mined transaction therefore says nothing on its own about what was
 * funded — decode the receipt with {@link decodeCycleEvents} to find out.
 *
 * @example
 * const hash = await trigger(walletClient, {
 *   registry: '0x…',
 *   volumeIds: plan.volumeIds,
 * })
 */
export async function trigger<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: TriggerParameters,
): Promise<TriggerReturnType> {
  const {
    registry,
    volumeIds,
    account = client.account,
    chain = client.chain,
    gasMultiplier = 1.2,
  } = parameters;

  const call = {
    address: registry,
    abi: registryAbi,
    functionName: "trigger",
    args: [volumeIds],
    account,
    chain,
  } as const;

  // No simulate pass: the contract's per-item try/catch means `trigger` has no
  // top-level revert to catch, so an eth_call would only cost a round trip.
  // Estimation surfaces a bad address or ABI just as well.
  const gas =
    parameters.gas ??
    scaleGas(
      await getAction(
        client,
        estimateContractGas,
        "estimateContractGas",
      )(call as never),
      gasMultiplier,
    );

  return getAction(client, writeContract, "writeContract")({ ...call, gas } as never);
}
