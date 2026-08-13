# gas-boy

Cloudflare Worker that runs one `runKeeperCycle` from [`ethswarm-volume-keeper`](../../packages/ethswarm-volume-keeper) per cron tick.

This is the bot; everything the library leaves out lives here — `src/client.ts` (env, keys, supported chains, transport) and `src/index.ts` (cron, `/health`, caching, logging).

You supply the RPC. `RPC_URL` is required and no endpoints ship with this worker; comma-separate several to fail over between them.

## Local

```bash
cp .dev.vars.example .dev.vars    # then edit
bun run dev                       # builds the package, then wrangler dev on :8787

curl localhost:8787/health
curl "localhost:8787/cdn-cgi/handler/scheduled?cron=*+*+*+*+*"   # force one cycle
```

Top-level config points at Sepolia, so a local run does something real. `DRY_RUN="true"` plans and simulates without sending.

## Deploy

```bash
wrangler secret put PRIVATE_KEY --env production
wrangler secret put RPC_URL --env production      # a secret, it usually embeds an API key
bun run deploy:prod                # Gnosis, hourly
bun run deploy:sepolia             # Sepolia, every minute
```

Fund the keeper EOA with xDAI (or Sepolia ETH) and nothing else — it pays gas and never touches BZZ.

## Adding a deployment

One env per registry in `wrangler.jsonc`, then `wrangler secret put PRIVATE_KEY --env <name>`:

```jsonc
"my-deployment": {
  "vars": { "CHAIN_ID": "100", "REGISTRY_ADDRESS": "0x…" },
  "triggers": { "crons": ["0 * * * *"] }
}
```

Gnosis and Sepolia are the supported chains; adding another means an entry in `CHAINS` in `src/client.ts`, and its viem `Chain` must carry `contracts.multicall3`. Give the cron slack: each top-up buys `graceBlocks` of runway, so hourly against Gnosis's ~24 h window survives many missed runs — Sepolia's `graceBlocks = 12` is why that env sits at the one-minute floor.

`CHAIN_ID` and `REGISTRY_ADDRESS` are vars, `PRIVATE_KEY` and `RPC_URL` are secrets, the rest are optional and listed in `.dev.vars.example`. There is no `POSTAGE_ADDRESS` — it's read from the registry's own immutable.

## Logs

One JSON line per cycle (`kind: "gas-boy/scheduled"`). A mined `trigger` doesn't mean a volume was funded, so read **`topupSkipped`**: `NoAuth` = that payer revoked, `PaymentFailed` = out of BZZ or allowance zeroed. Neither is the keeper's to fix. A **`failed`** tx with a hash was sent but not confirmed in time — nothing to do, the next cycle re-reads the chain and `trigger` is idempotent. **`warnings`** covers deferred work and a low keeper balance.

The handler never throws, so a bad cycle can't cause retry storms. Module-scope state (transport ranking, chain-id check, registry immutables) is a cache and safe to lose.
