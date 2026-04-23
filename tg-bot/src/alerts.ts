import type { Hex } from "viem";
import type { Alert, EnrichedVolume } from "./types";
import { shouldSend } from "./db";
import { formatLowBalance, formatPaymentsFailed } from "./format";

const COOLDOWN_LOW = 7200; // 2 hours
const COOLDOWN_PAY_FAIL = 1800; // 30 minutes

export function evaluateAlerts(
  chatId: number,
  volumes: EnrichedVolume[],
  paymentFailures: Set<Hex>,
): Alert[] {
  const alerts: Alert[] = [];

  // Per-volume: low balance warnings
  for (const v of volumes) {
    const warnTarget = v.target / 2n;
    if (v.remaining < warnTarget) {
      const key = `low:${v.volumeId}`;
      if (shouldSend(chatId, key, COOLDOWN_LOW)) {
        alerts.push({
          type: "LOW_BALANCE",
          chatId,
          alertKey: key,
          message: formatLowBalance(v),
        });
      }
    }
  }

  // Grouped: payment failures — one message for all affected volumes
  const failedVolumes = volumes.filter((v) => paymentFailures.has(v.volumeId));
  if (failedVolumes.length > 0) {
    // Use a single dedup key for the group (keyed by payer, since a revoked
    // allowance affects all volumes under the same payer).
    const payer = failedVolumes[0]!.payer;
    const key = `pay_fail:${payer}`;
    if (shouldSend(chatId, key, COOLDOWN_PAY_FAIL)) {
      alerts.push({
        type: "PAYMENT_FAILED",
        chatId,
        alertKey: key,
        message: formatPaymentsFailed(failedVolumes),
      });
    }
  }

  return alerts;
}
