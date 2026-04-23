import { Bot } from "grammy";
import { getAddress } from "viem";
import type { Hex, PublicClient } from "viem";
import type { Env } from "./types";
import { setWatch, removeWatch, getWatch } from "./db";
import { getVolumesForAddress, getBzzBalance } from "./chain";
import { formatStatusReport } from "./format";

export function createBot(env: Env, client: PublicClient): Bot {
  const bot = new Bot(env.TELEGRAM_BOT_TOKEN);

  bot.command("start", (ctx) =>
    ctx.reply(
      [
        "Swarm Volume Watchdog",
        "",
        "I monitor your VolumeRegistry volumes and notify you when:",
        "- A volume's balance drops below half the grace period",
        "- A keeper payment fails",
        "",
        "Commands:",
        "/watch <address> - set address to monitor",
        "/unwatch - stop monitoring",
        "/status - current volumes and BZZ balance",
        "/help - show this message",
      ].join("\n"),
    ),
  );

  bot.command("help", (ctx) =>
    ctx.reply(
      [
        "/watch <address> - set address to monitor (owner or payer)",
        "/unwatch - stop monitoring",
        "/status - current volumes and BZZ balance",
      ].join("\n"),
    ),
  );

  bot.command("watch", async (ctx) => {
    const text = ctx.message?.text ?? "";
    const parts = text.split(/\s+/);
    const raw = parts[1];
    if (!raw) return ctx.reply("Usage: /watch <ethereum-address>");

    let address: Hex;
    try {
      address = getAddress(raw) as Hex;
    } catch {
      return ctx.reply("Invalid Ethereum address.");
    }

    setWatch(ctx.chat.id, address);
    await ctx.reply(`Watching ${address}\nFetching current status...`);

    try {
      const [volumes, balance] = await Promise.all([
        getVolumesForAddress(client, env, address),
        getBzzBalance(client, env.BZZ_ADDRESS, address),
      ]);
      await ctx.reply(formatStatusReport(address, volumes, balance, 13.5), {
        parse_mode: "MarkdownV2",
      });
    } catch (err) {
      await ctx.reply(`Could not fetch on-chain data: ${err instanceof Error ? err.message : String(err)}`);
    }
  });

  bot.command("unwatch", (ctx) => {
    const existing = getWatch(ctx.chat.id);
    if (!existing) return ctx.reply("No address being watched.");
    removeWatch(ctx.chat.id);
    return ctx.reply(`Stopped watching ${existing.address}`);
  });

  bot.command("status", async (ctx) => {
    const watch = getWatch(ctx.chat.id);
    if (!watch) return ctx.reply("No address being watched. Use /watch <address> first.");

    try {
      const address = watch.address as Hex;
      const [volumes, balance] = await Promise.all([
        getVolumesForAddress(client, env, address),
        getBzzBalance(client, env.BZZ_ADDRESS, address),
      ]);
      await ctx.reply(formatStatusReport(watch.address, volumes, balance, 13.5), {
        parse_mode: "MarkdownV2",
      });
    } catch (err) {
      await ctx.reply(`Error fetching status: ${err instanceof Error ? err.message : String(err)}`);
    }
  });

  return bot;
}
