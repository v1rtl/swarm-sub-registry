import { runKeepalive, type Env } from "./registry";

export default {
  async scheduled(
    controller: ScheduledController,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<void> {
    // Fire-and-observe: keep the Worker alive until the keepalive call
    // finishes, but never throw — throwing out of scheduled() causes
    // retries and alarm storms.
    const task = (async () => {
      const result = await runKeepalive(env);
      console.log(
        JSON.stringify({
          kind: "gas-boy/scheduled",
          cron: controller.cron,
          scheduledTime: controller.scheduledTime,
          ...result,
        }),
      );
    })();
    ctx.waitUntil(task);
    await task;
  },

  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/trigger") {
      const result = await runKeepalive(env);
      console.log(
        JSON.stringify({ kind: "gas-boy/trigger", ...result }),
      );
      return new Response(JSON.stringify(result, null, 2), {
        status: result.ok ? 200 : 500,
        headers: { "content-type": "application/json" },
      });
    }
    if (url.pathname === "/health") {
      return new Response("gas-boy ok\n", { status: 200 });
    }
    return new Response(
      "gas-boy — endpoints: /trigger (run keepalive now), /health\n",
      { status: 200 },
    );
  },
} satisfies ExportedHandler<Env>;
