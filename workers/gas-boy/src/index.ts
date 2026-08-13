import { runKeeperCycle, type RegistryConfig } from "ethswarm-volume-keeper";
import { buildClient, readOptions, type Env } from "./client";

// Held at module scope so it survives between cron invocations in the same
// isolate: the fallback transport keeps its endpoint ranking, the chain-id
// check runs once, and the registry's immutables stay cached.
let client: ReturnType<typeof buildClient> | undefined;
let registryConfig: RegistryConfig | undefined;
let chainVerified = false;
let inFlight = false;

async function cycle(env: Env) {
  const options = readOptions(env);
  client ??= buildClient(env);

  // Catch "pointed at the wrong network" before it looks like an empty registry.
  if (!chainVerified) {
    const actual = await client.getChainId();
    if (actual !== client.chain.id) {
      throw new Error(
        `RPC reports chain id ${actual} but CHAIN_ID says ${client.chain.id}`,
      );
    }
    chainVerified = true;
  }

  const result = await runKeeperCycle(client, {
    registry: options.registry,
    mode: options.mode,
    dryRun: options.dryRun,
    maxIdsPerTx: options.maxIdsPerTx,
    maxTxPerCycle: options.maxTxPerCycle,
    pageSize: options.pageSize,
    registryConfig,
  });

  // postage and graceBlocks are constructor-immutable; keep what this cycle
  // already read so later cycles skip that multicall entirely.
  registryConfig ??= result.registryConfig;

  const warnings = [...result.warnings];
  if (options.minBalanceWei > 0n) {
    const balance = await client.getBalance({ address: client.account.address });
    if (balance < options.minBalanceWei) {
      warnings.push(
        `keeper balance ${balance} wei is below the configured floor ${options.minBalanceWei} wei`,
      );
    }
  }

  return { ...result, warnings, keeper: client.account.address, chainId: client.chain.id };
}

export default {
  async scheduled(
    controller: ScheduledController,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<void> {
    // Fire-and-observe: keep the Worker alive until the cycle finishes, but
    // never throw — throwing out of scheduled() causes retries and alarm
    // storms. runKeeperCycle folds its own failures into the result; only a
    // configuration error can escape it.
    const task = (async () => {
      if (inFlight) {
        console.warn(
          JSON.stringify({ kind: "gas-boy/skipped", reason: "cycle already in flight" }),
        );
        return;
      }
      inFlight = true;
      try {
        const result = await cycle(env);
        console.log(
          JSON.stringify(
            {
              kind: "gas-boy/scheduled",
              cron: controller.cron,
              scheduledTime: controller.scheduledTime,
              ...result,
            },
            (_, value) => (typeof value === "bigint" ? value.toString() : value),
          ),
        );
      } catch (err) {
        console.error(
          JSON.stringify({
            kind: "gas-boy/error",
            cron: controller.cron,
            error: err instanceof Error ? err.message : String(err),
          }),
        );
      } finally {
        inFlight = false;
      }
    })();

    ctx.waitUntil(task);
    await task;
  },

  async fetch(req: Request, _env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") {
      return new Response("gas-boy ok\n", { status: 200 });
    }
    return new Response("gas-boy — endpoint: /health (runs on cron)\n", {
      status: 200,
    });
  },
} satisfies ExportedHandler<Env>;
