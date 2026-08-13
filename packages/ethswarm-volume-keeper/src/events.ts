import { parseEventLogs, type Address, type Hex, type Log } from "viem";
import { RETIRE_REASONS, SKIP_REASONS, registryAbi } from "./abi.js";
import type { VolumeOutcome } from "./types.js";

export interface DecodedEvents {
  toppedUp: Array<{ volumeId: Hex; amount: bigint }>;
  retired: VolumeOutcome[];
  topupSkipped: VolumeOutcome[];
}

const name = (table: Record<number, string>, reason: number): string =>
  table[reason] ?? `Unknown(${reason})`;

/**
 * Turn a `trigger` receipt into per-volume outcomes.
 *
 * `trigger(bytes32[])` swallows per-item reverts, so a mined transaction says
 * nothing on its own about whether a volume was actually funded. These events
 * are the only place the contract explains itself — a `TopupSkipped` reason
 * distinguishes "the payer revoked authorization" from "the payer is out of
 * BZZ", which is exactly what an operator needs to see.
 */
export function decodeCycleEvents(
  logs: readonly Log[],
  registry: Address,
): DecodedEvents {
  const decoded: DecodedEvents = { toppedUp: [], retired: [], topupSkipped: [] };
  const fromRegistry = logs.filter(
    (log) => log.address.toLowerCase() === registry.toLowerCase(),
  );

  for (const log of parseEventLogs({ abi: registryAbi, logs: fromRegistry })) {
    switch (log.eventName) {
      case "Toppedup":
        decoded.toppedUp.push({
          volumeId: log.args.volumeId,
          amount: log.args.amount,
        });
        break;
      case "VolumeRetired":
        decoded.retired.push({
          volumeId: log.args.volumeId,
          reason: name(RETIRE_REASONS, log.args.reason),
        });
        break;
      case "TopupSkipped":
        decoded.topupSkipped.push({
          volumeId: log.args.volumeId,
          reason: name(SKIP_REASONS, log.args.reason),
        });
        break;
    }
  }

  return decoded;
}
