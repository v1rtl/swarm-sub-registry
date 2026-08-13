import type { Account, Address, Chain, Client, Transport } from "viem";
import {
  collectActiveVolumes,
  type CollectActiveVolumesParameters,
} from "../actions/collectActiveVolumes.js";
import {
  getActiveVolumeCount,
  type GetActiveVolumeCountParameters,
} from "../actions/getActiveVolumeCount.js";
import {
  getActiveVolumes,
  type GetActiveVolumesParameters,
} from "../actions/getActiveVolumes.js";
import {
  getBatchStates,
  type GetBatchStatesParameters,
} from "../actions/getBatchStates.js";
import {
  getKeeperPlan,
  type GetKeeperPlanParameters,
} from "../actions/getKeeperPlan.js";
import {
  getRegistryConfig,
  type GetRegistryConfigParameters,
} from "../actions/getRegistryConfig.js";
import { getVolume, type GetVolumeParameters } from "../actions/getVolume.js";

type Bound<parameters> = Omit<parameters, "registry">;

/**
 * Read actions for a VolumeRegistry, with the registry address bound.
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { gnosis } from 'viem/chains'
 * import { volumeRegistryActions } from 'ethswarm-volume-keeper'
 *
 * const client = createPublicClient({
 *   chain: gnosis,
 *   transport: http(),
 * }).extend(volumeRegistryActions({ registry: '0x…' }))
 *
 * const plan = await client.getKeeperPlan()
 */
export function volumeRegistryActions({ registry }: { registry: Address }) {
  return <
    transport extends Transport,
    chain extends Chain | undefined,
    account extends Account | undefined,
  >(
    client: Client<transport, chain, account>,
  ) => ({
    getActiveVolumeCount: (args: Bound<GetActiveVolumeCountParameters> = {}) =>
      getActiveVolumeCount(client, { ...args, registry }),
    getActiveVolumes: (args: Bound<GetActiveVolumesParameters> = {}) =>
      getActiveVolumes(client, { ...args, registry }),
    getVolume: (args: Bound<GetVolumeParameters>) =>
      getVolume(client, { ...args, registry }),
    getRegistryConfig: (args: Bound<GetRegistryConfigParameters> = {}) =>
      getRegistryConfig(client, { ...args, registry }),
    getBatchStates: (args: GetBatchStatesParameters) =>
      getBatchStates(client, args),
    collectActiveVolumes: (args: Bound<CollectActiveVolumesParameters> = {}) =>
      collectActiveVolumes(client, { ...args, registry }),
    getKeeperPlan: (args: Bound<GetKeeperPlanParameters> = {}) =>
      getKeeperPlan(client, { ...args, registry }),
  });
}
