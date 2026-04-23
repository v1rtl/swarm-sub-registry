import type { Hex } from "viem";

export interface Env {
  TELEGRAM_BOT_TOKEN: string;
  RPC_URL: string;
  CHAIN_ID: string;
  REGISTRY_ADDRESS: Hex;
  POSTAGE_ADDRESS: Hex;
  BZZ_ADDRESS: Hex;
  POLL_INTERVAL_MS?: string;
  DB_PATH?: string;
}

export interface VolumeView {
  volumeId: Hex;
  owner: Hex;
  payer: Hex;
  chunkSigner: Hex;
  createdAt: bigint;
  ttlExpiry: bigint;
  depth: number;
  status: number;
  accountActive: boolean;
}

export interface EnrichedVolume {
  volumeId: Hex;
  owner: Hex;
  payer: Hex;
  depth: number;
  status: number;
  remaining: bigint;
  target: bigint;
  lastPrice: bigint;
  graceBlocks: bigint;
}

export type AlertType = "LOW_BALANCE" | "PAYMENT_FAILED";

export interface Alert {
  type: AlertType;
  chatId: number;
  alertKey: string;
  message: string;
}

export interface WatchRow {
  chat_id: number;
  address: string;
  created_at: number;
}
