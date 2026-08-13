# ethswarm-volume-keeper

viem actions for [Swarm](https://www.ethswarm.org/) Volume Registries — read what needs topping up, and top it up.

Actions take a client you built, like viem's own. No transports, chain table, RPC list, key handling or env parsing in here; that's yours.

```bash
bun add ethswarm-volume-keeper viem   # viem is a peer dependency
```

## Usage

```ts
import { createPublicClient, http } from "viem";
import { gnosis } from "viem/chains";
import { getKeeperPlan } from "ethswarm-volume-keeper";

const client = createPublicClient({ chain: gnosis, transport: http() });
const plan = await getKeeperPlan(client, { registry: "0x…" });
// plan.due, plan.dead, plan.noAuth, plan.volumeIds
```

Keeping volumes alive needs a client that can write:

```ts
const client = createWalletClient({
  account: privateKeyToAccount(process.env.PRIVATE_KEY),
  chain: gnosis,
  transport: http(process.env.RPC_URL),
}).extend(publicActions);

const result = await runKeeperCycle(client, { registry: "0x…" });
```

Or bind the registry once:

```ts
client
  .extend(volumeRegistryActions({ registry }))  // reads
  .extend(keeperActions({ registry }));         // writes

await client.getKeeperPlan();
await client.runKeeperCycle();
```

## Actions

| Read | |
|---|---|
| `getActiveVolumeCount` | size of the active index |
| `getActiveVolumes` | one page of it |
| `collectActiveVolumes` | all of it, paged through Multicall3 at a pinned block |
| `getVolume` | one volume by id (unknown ids come back zeroed, not reverted) |
| `getRegistryConfig` | the immutables: `postage`, `graceBlocks` |
| `getBatchStates` | PostageStamp records for a set of volumes, plus `lastPrice` / `currentTotalOutPayment` |
| `getKeeperPlan` | all of the above, triaged: what a cycle *would* do |

| Write | |
|---|---|
| `trigger` | top up (or retire) a batch of volumes |
| `reap` | retire one TTL-expired volume |
| `runKeeperCycle` | plan, chunk, send, decode receipts |

Pure, no I/O: `triage`, `decodeCycleEvents`, `chunk`.

## Modes

```ts
mode: { type: "all" }                                  // default — the whole active index
mode: { type: "selected", volumeIds: ["0x…", "0x…"] }  // only these
```

`selected` reads each id directly. Ids that aren't `Active` volumes come back in `notActive` and are ignored; nothing else in the registry is touched.

## `runKeeperCycle` options

| | Default | |
|---|---|---|
| `registry` | — | required |
| `mode` | `{ type: "all" }` | |
| `pageSize` | `100` | volumes per read page |
| `registryConfig` | read on chain | pass back `result.registryConfig` to skip the read |
| `maxIdsPerTx` | `50` | |
| `maxTxPerCycle` | `8` | overflow defers to the next cycle, noted in `warnings` |
| `gasMultiplier` | `1.2` | headroom over the estimate — load-bearing, see below |
| `confirmations` | `1` | |
| `receiptTimeout` / `cycleTimeout` | `60_000` / `120_000` | ms |
| `dryRun` | `false` | simulate everything, send nothing |

## Result

```ts
{
  ok, error?, skipped?, durationMs
  blockNumber?, registryConfig?
  volumeCount, dueCount, deadCount, healthyCount, noAuthCount
  txs: [{ volumeIds, status, hash?, gasUsed?, error? }]
  toppedUp: [{ volumeId, amount }]
  retired: [{ volumeId, reason }]       // OwnerDeleted | VolumeExpired | …
  topupSkipped: [{ volumeId, reason }]  // NoAuth | PaymentFailed
  notActive, warnings
}
```

## Worth knowing

- **`runKeeperCycle` never throws.** Failures land in `ok`/`error` — throwing out of a cron handler causes retry storms.
- **A mined `trigger` doesn't mean anything was funded.** The contract swallows per-item failures; `topupSkipped` is where it explains itself. `NoAuth` = payer revoked, `PaymentFailed` = payer out of BZZ or allowance zeroed.
- **Reads are pinned to one block.** The active index is swap-and-pop, so paging across block heights can silently skip a volume. Pass `blockNumber` if you call `collectActiveVolumes` yourself.
- **Running short on gas fails silently.** Each id runs in a `try/catch` and an inner call gets 63/64 of the remaining gas, so an under-estimate makes inner calls OOG, get swallowed, and the transaction succeed having done nothing. Hence `gasMultiplier`, and deliberately no gas cap — a ceiling below what the batch needs would drop volumes just as quietly. Bound work with `maxIdsPerTx`; unused gas is refunded, so over-estimating is free.
- **Volumes with no active payer are never sent.** `trigger` would only emit `TopupSkipped(NoAuth)` and burn gas. They surface as `noAuthCount`.
- **PostageStamp and `graceBlocks` are read from the registry**, never configured — both are constructor-immutable.
- **Safe to run two keepers.** `trigger` tops up to a target, so the second computes a zero deficit. Redundancy, not double-spend.
- **Failover is yours:** `fallback([http(primary), http(secondary)], { rank: … })`. `rank` keeps a timer alive, so a one-shot script needs `process.exit()`.

Contract semantics — volume lifecycle, the owner/payer handshake, retirement edges, the `graceBlocks` guarantee — live in the registry's own design doc. This package assumes that contract and doesn't extend it.
