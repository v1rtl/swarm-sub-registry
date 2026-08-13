import { zeroAddress, type Address, type Hex } from "viem";
import { VOLUME_STATUS } from "./abi.js";
import type { VolumeView } from "./types.js";

/** PostageStamp `batches(id)` fields the triage needs. */
export interface BatchState {
  owner: Address;
  depth: number;
  normalisedBalance: bigint;
}

/** Chain-wide values shared by every volume in a cycle. */
export interface ChainState {
  /** `PostageStamp.lastPrice()` — per chunk, per block. */
  lastPrice: bigint;
  /** `PostageStamp.currentTotalOutPayment()`. */
  outPayment: bigint;
  /** `VolumeRegistry.graceBlocks()` — constructor-immutable. */
  graceBlocks: bigint;
  /** Timestamp of the pinned block, for the TTL edge. */
  timestamp: bigint;
}

/**
 * Why a volume is past saving. Names mirror the registry's own
 * `VolumeRetired` reasons; the contract makes the final call when the id is
 * included in `trigger`.
 */
export type DeadReason =
  | "batchMissing"
  | "batchExpired"
  | "ownerMismatch"
  | "depthChanged"
  | "ttlExpired";

export interface DeadVolume {
  volume: VolumeView;
  reason: DeadReason;
}

export interface TriageResult {
  /** Underfunded and payable — the work that matters. */
  due: VolumeView[];
  /** Retire-worthy; including them in `trigger` cleans the active index. */
  dead: DeadVolume[];
  /** Underfunded but with no active payer account. Sending would only emit
   *  `TopupSkipped(NoAuth)` and burn gas, so they are reported, not sent. */
  noAuth: VolumeView[];
  /** Active, funded, nothing to do. */
  healthy: VolumeView[];
}

/**
 * Client-side classification, pure and total.
 *
 * Check order mirrors `VolumeRegistry._triggerOne` exactly — batch, owner,
 * depth, TTL, then auth, then deficit — so a lapsed authorization never masks
 * a dead batch. The contract re-derives all of this on chain, so a false
 * positive here costs gas, never correctness.
 *
 * `batches[i]` is the PostageStamp record for `volumes[i]`; a missing entry
 * (index gap) is treated as a dead batch.
 */
export function triage(
  volumes: readonly VolumeView[],
  batches: readonly (BatchState | undefined)[],
  state: ChainState,
): TriageResult {
  const result: TriageResult = { due: [], dead: [], noAuth: [], healthy: [] };
  const target = state.lastPrice * state.graceBlocks;

  volumes.forEach((volume, i) => {
    if (volume.status !== VOLUME_STATUS.active) {
      result.dead.push({ volume, reason: "batchMissing" });
      return;
    }

    const batch = batches[i];
    if (!batch || batch.owner === zeroAddress) {
      result.dead.push({ volume, reason: "batchMissing" });
      return;
    }
    if (batch.normalisedBalance <= state.outPayment) {
      result.dead.push({ volume, reason: "batchExpired" });
      return;
    }
    if (batch.owner.toLowerCase() !== volume.chunkSigner.toLowerCase()) {
      result.dead.push({ volume, reason: "ownerMismatch" });
      return;
    }
    if (batch.depth !== volume.depth) {
      result.dead.push({ volume, reason: "depthChanged" });
      return;
    }
    if (volume.ttlExpiry !== 0n && state.timestamp >= volume.ttlExpiry) {
      result.dead.push({ volume, reason: "ttlExpired" });
      return;
    }

    const remaining = batch.normalisedBalance - state.outPayment;
    if (remaining >= target) {
      result.healthy.push(volume);
      return;
    }
    if (!volume.accountActive) {
      result.noAuth.push(volume);
      return;
    }
    result.due.push(volume);
  });

  return result;
}

/**
 * Ids for one cycle's `trigger` calls: top-ups first, cleanup after, so a
 * gas-capped transaction spends its budget on volumes that are still alive.
 */
export function triggerIds(result: TriageResult): Hex[] {
  return [
    ...result.due.map((v) => v.volumeId),
    ...result.dead.map((d) => d.volume.volumeId),
  ];
}

/** Split into fixed-size chunks, preserving order. */
export function chunk<T>(items: readonly T[], size: number): T[][] {
  if (size < 1) throw new Error(`chunk size must be >= 1, got ${size}`);
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}
