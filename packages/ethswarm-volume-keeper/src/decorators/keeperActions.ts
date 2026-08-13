import type { Account, Address, Chain, Client, Transport } from "viem";
import { reap, type ReapParameters } from "../actions/reap.js";
import {
  runKeeperCycle,
  type RunKeeperCycleParameters,
} from "../actions/runKeeperCycle.js";
import { trigger, type TriggerParameters } from "../actions/trigger.js";

type Bound<parameters> = Omit<parameters, "registry">;

/**
 * Write actions for a VolumeRegistry, with the registry address bound.
 *
 * Needs a client that can both read and write — a wallet client extended with
 * `publicActions`.
 *
 * @example
 * import { createWalletClient, http, publicActions } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { gnosis } from 'viem/chains'
 * import { keeperActions, volumeRegistryActions } from 'ethswarm-volume-keeper'
 *
 * const client = createWalletClient({
 *   account: privateKeyToAccount('0x…'),
 *   chain: gnosis,
 *   transport: http(),
 * })
 *   .extend(publicActions)
 *   .extend(volumeRegistryActions({ registry: '0x…' }))
 *   .extend(keeperActions({ registry: '0x…' }))
 *
 * const result = await client.runKeeperCycle()
 */
export function keeperActions({ registry }: { registry: Address }) {
  return <
    transport extends Transport,
    chain extends Chain | undefined,
    account extends Account | undefined,
  >(
    client: Client<transport, chain, account>,
  ) => ({
    trigger: (args: Bound<TriggerParameters>) =>
      trigger(client, { ...args, registry }),
    reap: (args: Bound<ReapParameters>) => reap(client, { ...args, registry }),
    runKeeperCycle: (args: Bound<RunKeeperCycleParameters> = {}) =>
      runKeeperCycle(client, { ...args, registry }),
  });
}
