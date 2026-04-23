import type { Hex } from "viem";
import type { Env } from "./types";
import { initDb } from "./db";
import { createClient } from "./chain";
import { createBot } from "./bot";
import { startPoller } from "./poller";

function loadEnv(): Env {
  const required = [
    "TELEGRAM_BOT_TOKEN",
    "RPC_URL",
    "CHAIN_ID",
    "REGISTRY_ADDRESS",
    "POSTAGE_ADDRESS",
    "BZZ_ADDRESS",
  ] as const;
  for (const key of required) {
    if (!process.env[key]) throw new Error(`Missing env var: ${key}`);
  }
  return {
    TELEGRAM_BOT_TOKEN: process.env.TELEGRAM_BOT_TOKEN!,
    RPC_URL: process.env.RPC_URL!,
    CHAIN_ID: process.env.CHAIN_ID!,
    REGISTRY_ADDRESS: process.env.REGISTRY_ADDRESS! as Hex,
    POSTAGE_ADDRESS: process.env.POSTAGE_ADDRESS! as Hex,
    BZZ_ADDRESS: process.env.BZZ_ADDRESS! as Hex,
    POLL_INTERVAL_MS: process.env.POLL_INTERVAL_MS,
    DB_PATH: process.env.DB_PATH,
  };
}

const env = loadEnv();
const dbPath = env.DB_PATH ?? "./data/tg-bot.db";
initDb(dbPath);

const client = createClient(env);
const bot = createBot(env, client);
const timer = startPoller(env, client, bot);

console.log("tg-bot starting...");
bot.start({
  onStart: () => console.log("tg-bot running"),
});

// Graceful shutdown
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    console.log(`\n${sig} received, shutting down...`);
    clearInterval(timer);
    bot.stop();
    process.exit(0);
  });
}
