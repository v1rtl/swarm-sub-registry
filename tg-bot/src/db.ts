import { Database } from "bun:sqlite";
import type { WatchRow } from "./types";

let db: Database;

export function initDb(path: string): Database {
  db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode=WAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS watch (
      chat_id    INTEGER PRIMARY KEY,
      address    TEXT NOT NULL,
      created_at INTEGER NOT NULL DEFAULT (unixepoch())
    )
  `);
  db.exec(`
    CREATE TABLE IF NOT EXISTS sent_alerts (
      chat_id   INTEGER NOT NULL,
      alert_key TEXT NOT NULL,
      sent_at   INTEGER NOT NULL DEFAULT (unixepoch()),
      PRIMARY KEY (chat_id, alert_key)
    )
  `);
  return db;
}

export function getDb(): Database {
  return db;
}

export function setWatch(chatId: number, address: string): void {
  db.run(
    `INSERT INTO watch (chat_id, address) VALUES (?, ?)
     ON CONFLICT(chat_id) DO UPDATE SET address = excluded.address`,
    [chatId, address],
  );
}

export function removeWatch(chatId: number): void {
  db.run("DELETE FROM watch WHERE chat_id = ?", [chatId]);
  db.run("DELETE FROM sent_alerts WHERE chat_id = ?", [chatId]);
}

export function getWatch(chatId: number): WatchRow | null {
  return db.query("SELECT * FROM watch WHERE chat_id = ?").get(chatId) as WatchRow | null;
}

export function getAllWatches(): WatchRow[] {
  return db.query("SELECT * FROM watch").all() as WatchRow[];
}

// Dedup: returns true if alert should be sent (not recently sent)
export function shouldSend(chatId: number, alertKey: string, cooldownSeconds: number): boolean {
  const row = db
    .query("SELECT sent_at FROM sent_alerts WHERE chat_id = ? AND alert_key = ?")
    .get(chatId, alertKey) as { sent_at: number } | null;
  if (!row) return true;
  return Math.floor(Date.now() / 1000) - row.sent_at > cooldownSeconds;
}

export function markSent(chatId: number, alertKey: string): void {
  db.run(
    `INSERT INTO sent_alerts (chat_id, alert_key, sent_at) VALUES (?, ?, unixepoch())
     ON CONFLICT(chat_id, alert_key) DO UPDATE SET sent_at = unixepoch()`,
    [chatId, alertKey],
  );
}

export function cleanupOldAlerts(): void {
  db.run("DELETE FROM sent_alerts WHERE sent_at < unixepoch() - 86400");
}
