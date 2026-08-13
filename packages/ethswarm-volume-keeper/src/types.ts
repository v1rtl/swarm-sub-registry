import type { Address, Hex, ReadContractReturnType } from "viem";
import type { registryAbi } from "./abi.js";

/** One row of `getActiveVolumes` / `getVolume`, inferred straight from the ABI. */
export type VolumeView = ReadContractReturnType<
  typeof registryAbi,
  "getActiveVolumes"
>[number];

/**
 * Which volumes a keeper maintains.
 *
 * - `all` — every volume in the registry's active index.
 * - `selected` — only the listed ids. Ids that are not `Active` (never
 *   created, already retired) are reported and ignored, never fatal.
 */
export type KeeperMode =
  | { type: "all" }
  | { type: "selected"; volumeIds: readonly Hex[] };

/** The registry's constructor-immutable wiring. */
export interface RegistryConfig {
  postage: Address;
  graceBlocks: bigint;
}

export interface TxResult {
  volumeIds: readonly Hex[];
  /**
   * - `success` / `reverted` — mined, per the receipt.
   * - `simulated` — dry run; nothing was sent.
   * - `failed` — never mined: simulation reverted, the send failed, or the
   *   receipt wait timed out.
   */
  status: "success" | "reverted" | "simulated" | "failed";
  hash?: Hex;
  blockNumber?: bigint;
  gasUsed?: bigint;
  error?: string;
}

export interface VolumeOutcome {
  volumeId: Hex;
  reason: string;
}
