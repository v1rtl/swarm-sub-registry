import type { Hex } from "viem";
import type { EnrichedVolume } from "./types";

// MarkdownV2 requires escaping these characters outside of code spans.
function esc(s: string): string {
  return s.replace(/([_*\[\]()~`>#\+\-=|{}.!\\])/g, "\\$1");
}

function short(hex: Hex): string {
  return `${hex.slice(0, 10)}…${hex.slice(-6)}`;
}

function bzzFromPlur(plur: bigint): string {
  const whole = plur / 10_000_000_000_000_000n;
  const frac = plur % 10_000_000_000_000_000n;
  const fracStr = frac.toString().padStart(16, "0").slice(0, 4);
  return `${whole}.${fracStr}`;
}

function estimateBlocksRemaining(v: EnrichedVolume): bigint {
  if (v.lastPrice === 0n) return 0n;
  return v.remaining / v.lastPrice;
}

function blocksToTime(blocks: bigint, blockTimeSec: number): string {
  const totalSec = Number(blocks) * blockTimeSec;
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);
  if (hours > 0) return `~${hours}h ${minutes}m`;
  return `~${minutes}m`;
}

export function formatVolumeStatus(v: EnrichedVolume, blockTimeSec: number): string {
  const blocks = estimateBlocksRemaining(v);
  const time = blocksToTime(blocks, blockTimeSec);
  const pct = v.target > 0n ? Number((v.remaining * 100n) / v.target) : 0;
  return [
    `Volume \`${short(v.volumeId)}\``,
    esc(`  depth: ${v.depth} | remaining: ${pct}% of grace`),
    esc(`  est. time left: ${time} (${blocks} blocks)`),
  ].join("\n");
}

export function formatLowBalance(v: EnrichedVolume): string {
  const blocks = estimateBlocksRemaining(v);
  const time = blocksToTime(blocks, 13.5);
  const pct = v.target > 0n ? Number((v.remaining * 100n) / v.target) : 0;
  return [
    esc("\u26a0\ufe0f Volume balance low"),
    ``,
    `Volume: \`${short(v.volumeId)}\``,
    esc(`Remaining: ${pct}% of grace period`),
    esc(`Est. time left: ${time}`),
    ``,
    esc("The volume balance is below half the grace period. If the keeper does not top it up soon, the batch may expire."),
  ].join("\n");
}

export function formatPaymentsFailed(volumes: EnrichedVolume[]): string {
  const lines: string[] = [
    esc(`\u274c Payment failed for ${volumes.length} volume${volumes.length > 1 ? "s" : ""}`),
    ``,
  ];
  for (const v of volumes) {
    lines.push(`  \`${short(v.volumeId)}\``);
  }
  lines.push(``);
  lines.push(`Payer: \`${short(volumes[0]!.payer)}\``);
  lines.push(``);
  lines.push(esc("The keeper tried to top up but the BZZ transfer from the payer failed. Check the payer's BZZ balance and allowance."));
  return lines.join("\n");
}

export function formatStatusReport(
  address: string,
  volumes: EnrichedVolume[],
  bzzBalance: bigint,
  blockTimeSec: number,
): string {
  const lines: string[] = [
    `Status for \`${address}\``,
    esc(`BZZ balance: ${bzzFromPlur(bzzBalance)} BZZ`),
    esc(`Active volumes: ${volumes.length}`),
  ];
  if (volumes.length > 0) {
    lines.push("");
    for (const v of volumes) {
      lines.push(formatVolumeStatus(v, blockTimeSec));
      lines.push("");
    }
  }
  return lines.join("\n");
}
