import type { Hex, PublicClient } from "viem";
import type { Bot } from "grammy";
import type { Env } from "./types";
import { getAllWatches, markSent, cleanupOldAlerts } from "./db";
import { getVolumesForAddress, getRecentPaymentFailures } from "./chain";
import { evaluateAlerts } from "./alerts";

// How many recent blocks to scan for TopupSkipped events each cycle.
// ~15 min of Sepolia blocks at ~13.5s/block.
const EVENT_LOOKBACK = 75n;

export function startPoller(env: Env, client: PublicClient, bot: Bot): NodeJS.Timer {
  const intervalMs = env.POLL_INTERVAL_MS ? Number(env.POLL_INTERVAL_MS) : 60_000;

  async function poll() {
    try {
      const watches = getAllWatches();
      if (watches.length === 0) return;

      // Get current block for event lookback
      const currentBlock = await client.getBlockNumber();
      const fromBlock = currentBlock > EVENT_LOOKBACK ? currentBlock - EVENT_LOOKBACK : 0n;

      // Fetch recent payment failures once for all watches
      const paymentFailures = await getRecentPaymentFailures(
        client,
        env.REGISTRY_ADDRESS,
        fromBlock,
      );

      for (const watch of watches) {
        try {
          const address = watch.address as Hex;
          const volumes = await getVolumesForAddress(client, env, address);
          const alerts = evaluateAlerts(watch.chat_id, volumes, paymentFailures);

          for (const alert of alerts) {
            try {
              await bot.api.sendMessage(alert.chatId, alert.message, {
                parse_mode: "MarkdownV2",
              });
              markSent(alert.chatId, alert.alertKey);
            } catch (err) {
              console.error(`Failed to send alert to ${alert.chatId}:`, err);
            }
          }
        } catch (err) {
          console.error(`Poll error for ${watch.address}:`, err);
        }
      }

      cleanupOldAlerts();
    } catch (err) {
      console.error("Poller cycle error:", err);
    }
  }

  // Run immediately, then on interval
  poll();
  return setInterval(poll, intervalMs);
}
