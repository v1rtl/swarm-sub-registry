import { describe, expect, test } from "bun:test";
import { zeroAddress } from "viem";
import {
  collectActiveVolumes,
  getActiveVolumeCount,
  getBatchStates,
  getKeeperPlan,
  getRegistryConfig,
  getVolume,
  keeperActions,
  runKeeperCycle,
  trigger,
  volumeRegistryActions,
} from "../src/index.js";
import {
  POSTAGE,
  REGISTRY,
  mockChain,
  volumeId,
  type MockVolume,
} from "./mock-chain.js";

const GRACE = 17_280n;
const PRICE = 44_445n;
const OUT = 1_000_000n;
const TARGET = GRACE * PRICE;

const funded = (n: number): MockVolume => ({
  volumeId: volumeId(n),
  batch: { normalisedBalance: OUT + TARGET * 2n },
});

const due = (n: number): MockVolume => ({
  volumeId: volumeId(n),
  batch: { normalisedBalance: OUT + 1n },
});

describe("read actions", () => {
  test("getRegistryConfig discovers PostageStamp and graceBlocks", async () => {
    const { client } = mockChain();
    expect(await getRegistryConfig(client, { registry: REGISTRY })).toEqual({
      postage: POSTAGE,
      graceBlocks: GRACE,
    });
  });

  test("getActiveVolumeCount counts the index", async () => {
    const { client } = mockChain({ volumes: [funded(1), funded(2)] });
    expect(await getActiveVolumeCount(client, { registry: REGISTRY })).toBe(2n);
  });

  test("getVolume returns a zeroed view for an unknown id", async () => {
    const { client } = mockChain({ volumes: [funded(1)] });
    const volume = await getVolume(client, {
      registry: REGISTRY,
      volumeId: volumeId(99),
    });
    expect(volume.status).toBe(0);
    expect(volume.owner).toBe(zeroAddress);
  });

  test("collectActiveVolumes pages 150 volumes through multicall", async () => {
    const volumes = Array.from({ length: 150 }, (_, i) => funded(i + 1));
    const chain = mockChain({ volumes });
    const { client } = chain;

    const collected = await collectActiveVolumes(client, { registry: REGISTRY });
    expect(collected).toHaveLength(150);
    expect(chain.multicallCount).toBeGreaterThan(0);
  });

  test("collectActiveVolumes on an empty registry does no page reads", async () => {
    const { client } = mockChain({ volumes: [] });
    expect(await collectActiveVolumes(client, { registry: REGISTRY })).toEqual([]);
  });

  test("getBatchStates aligns batches with the ids given", async () => {
    const { client } = mockChain({ volumes: [funded(1), due(2)] });
    const state = await getBatchStates(client, {
      postage: POSTAGE,
      volumeIds: [volumeId(2), volumeId(1)],
    });

    expect(state.lastPrice).toBe(PRICE);
    expect(state.outPayment).toBe(OUT);
    expect(state.batches[0]?.normalisedBalance).toBe(OUT + 1n);
    expect(state.batches[1]?.normalisedBalance).toBe(OUT + TARGET * 2n);
  });

  test("getBatchStates still reads the scalars with no volumes", async () => {
    const { client } = mockChain();
    const state = await getBatchStates(client, { postage: POSTAGE, volumeIds: [] });
    expect(state.lastPrice).toBe(PRICE);
    expect(state.batches).toEqual([]);
  });
});

describe("getKeeperPlan", () => {
  test("classifies without sending anything", async () => {
    const chain = mockChain({
      volumes: [funded(1), due(2), { volumeId: volumeId(3) }],
    });
    const { client } = chain;
    const plan = await getKeeperPlan(client, { registry: REGISTRY });

    expect(plan.healthy).toHaveLength(1);
    expect(plan.due).toHaveLength(1);
    expect(plan.dead).toHaveLength(1);
    expect(plan.volumeIds).toEqual([volumeId(2), volumeId(3)]);
    expect(chain.triggerCalls).toHaveLength(0);
  });

  test("pins every read to one block", async () => {
    const { client } = mockChain({ volumes: [funded(1)], blockNumber: 8_123_456n });
    const plan = await getKeeperPlan(client, { registry: REGISTRY });
    expect(plan.blockNumber).toBe(8_123_456n);
  });

  test("accepts a caller-pinned block", async () => {
    const { client } = mockChain({ volumes: [funded(1)] });
    const plan = await getKeeperPlan(client, {
      registry: REGISTRY,
      blockNumber: 8_000_000n,
    });
    expect(plan.blockNumber).toBe(8_000_000n);
  });

  test("a supplied registryConfig saves the immutables read", async () => {
    const withoutConfig = mockChain({ volumes: [funded(1)] });
    await getKeeperPlan(withoutConfig.client, { registry: REGISTRY });

    const withConfig = mockChain({ volumes: [funded(1)] });
    const plan = await getKeeperPlan(withConfig.client, {
      registry: REGISTRY,
      registryConfig: { postage: POSTAGE, graceBlocks: GRACE },
    });

    expect(plan.healthy).toHaveLength(1);
    expect(plan.registryConfig.postage).toBe(POSTAGE);
    expect(withConfig.multicallCount).toBe(withoutConfig.multicallCount - 1);
  });

  test("selected mode reads only the ids given and flags the rest", async () => {
    const { client } = mockChain({ volumes: [due(1), due(2), due(3)] });
    const plan = await getKeeperPlan(client, {
      registry: REGISTRY,
      mode: { type: "selected", volumeIds: [volumeId(2), volumeId(99)] },
    });

    expect(plan.volumeIds).toEqual([volumeId(2)]);
    expect(plan.notActive).toEqual([volumeId(99)]);
  });
});

describe("trigger", () => {
  test("sends the ids it was given", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    const { client } = chain;
    const hash = await trigger(client, {
      registry: REGISTRY,
      volumeIds: [volumeId(1)],
    });

    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(chain.triggerCalls).toEqual([[volumeId(1)]]);
  });

  test("an explicit gas limit skips estimation", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    const { client } = chain;
    await trigger(client, {
      registry: REGISTRY,
      volumeIds: [volumeId(1)],
      gas: 1_000_000n,
    });
    expect(chain.calls).not.toContain("eth_estimateGas");
    expect(chain.sentGas[0]).toBe(1_000_000n);
  });

  // trigger() has no top-level revert to catch — every id runs inside the
  // contract's own try/catch — so a simulate pass would only cost a round trip.
  test("does not spend an eth_call simulating first", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    await trigger(chain.client, { registry: REGISTRY, volumeIds: [volumeId(1)] });

    expect(chain.calls).toContain("eth_estimateGas");
    expect(chain.calls).not.toContain("eth_call");
  });

  // An under-estimate does not revert: the inner call OOGs, the catch swallows
  // it, and the transaction succeeds having topped up nothing. So the estimate
  // is scaled, and there is no cap that could silently claw it back.
  test("scales the estimate by gasMultiplier", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    await trigger(chain.client, { registry: REGISTRY, volumeIds: [volumeId(1)] });
    expect(chain.sentGas[0]).toBe((500_000n * 12n) / 10n); // mock estimates 500k

    const custom = mockChain({ volumes: [due(1)] });
    await trigger(custom.client, {
      registry: REGISTRY,
      volumeIds: [volumeId(1)],
      gasMultiplier: 2,
    });
    expect(custom.sentGas[0]).toBe(1_000_000n);
  });

  test("a large batch is not clamped", async () => {
    const chain = mockChain({ volumes: [due(1)], estimateGas: 40_000_000n });
    await trigger(chain.client, { registry: REGISTRY, volumeIds: [volumeId(1)] });
    expect(chain.sentGas[0]).toBe(48_000_000n);
  });
});

describe("runKeeperCycle", () => {
  test("an empty registry sends nothing", async () => {
    const chain = mockChain({ volumes: [] });
    const { client } = chain;
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.ok).toBe(true);
    expect(result.skipped).toBe("no active volumes");
    expect(chain.triggerCalls).toHaveLength(0);
  });

  test("a fully-funded registry sends nothing", async () => {
    const chain = mockChain({ volumes: [funded(1), funded(2)] });
    const { client } = chain;
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.skipped).toBe("nothing due or dead");
    expect(result.healthyCount).toBe(2);
    expect(chain.triggerCalls).toHaveLength(0);
  });

  test("one due volume out of three triggers exactly that id", async () => {
    const chain = mockChain({ volumes: [funded(1), due(2), funded(3)] });
    const { client } = chain;
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.ok).toBe(true);
    expect(result.dueCount).toBe(1);
    expect(chain.triggerCalls).toEqual([[volumeId(2)]]);
    expect(result.txs[0]?.status).toBe("success");
  });

  test("receipt events land in the result", async () => {
    const { client } = mockChain({ volumes: [due(1)] });
    const result = await runKeeperCycle(client, { registry: REGISTRY });
    expect(result.toppedUp).toEqual([{ volumeId: volumeId(1), amount: 1000n }]);
  });

  test("dead volumes are swept even when nothing is due", async () => {
    const chain = mockChain({ volumes: [{ volumeId: volumeId(1) }] });
    const { client } = chain;
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.deadCount).toBe(1);
    expect(chain.triggerCalls).toEqual([[volumeId(1)]]);
  });

  test("volumes with no active account are reported, never sent", async () => {
    const chain = mockChain({
      volumes: [{ ...due(1), accountActive: false }],
    });
    const { client } = chain;
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.noAuthCount).toBe(1);
    expect(chain.triggerCalls).toHaveLength(0);
  });

  test("ids are chunked across transactions", async () => {
    const volumes = Array.from({ length: 5 }, (_, i) => due(i + 1));
    const chain = mockChain({ volumes });
    const { client } = chain;
    const result = await runKeeperCycle(client, {
      registry: REGISTRY,
      maxIdsPerTx: 2,
    });

    expect(chain.triggerCalls.map((ids) => ids.length)).toEqual([2, 2, 1]);
    expect(result.txs).toHaveLength(3);
  });

  test("hitting maxTxPerCycle defers the rest and says so", async () => {
    const volumes = Array.from({ length: 5 }, (_, i) => due(i + 1));
    const chain = mockChain({ volumes });
    const { client } = chain;
    const result = await runKeeperCycle(client, {
      registry: REGISTRY,
      maxIdsPerTx: 2,
      maxTxPerCycle: 1,
    });

    expect(chain.triggerCalls).toHaveLength(1);
    expect(result.warnings.join(" ")).toContain("deferred");
  });

  test("a reverted transaction fails the cycle without throwing", async () => {
    const { client } = mockChain({ volumes: [due(1)], revertTx: true });
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.ok).toBe(false);
    expect(result.txs[0]?.status).toBe("reverted");
    expect(result.txs[0]?.hash).toBeDefined();
  });

  test("a dead RPC produces an error result, not a throw", async () => {
    const { client } = mockChain({ volumes: [due(1)], failWith: "socket hang up" });
    const result = await runKeeperCycle(client, { registry: REGISTRY });

    expect(result.ok).toBe(false);
    expect(result.error).toContain("socket hang up");
  });

  test("a stuck transaction keeps its hash for follow-up", async () => {
    const { client } = mockChain({ volumes: [due(1)], dropReceipts: true });
    const result = await runKeeperCycle(client, {
      registry: REGISTRY,
      receiptTimeout: 300,
    });

    expect(result.ok).toBe(false);
    expect(result.txs[0]?.status).toBe("failed");
    expect(result.txs[0]?.hash).toBeDefined();
  });

  test("dryRun simulates and sends nothing", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    const { client } = chain;
    const result = await runKeeperCycle(client, {
      registry: REGISTRY,
      dryRun: true,
    });

    expect(result.ok).toBe(true);
    expect(result.dueCount).toBe(1);
    expect(result.txs[0]?.status).toBe("simulated");
    expect(chain.triggerCalls).toHaveLength(0);
    expect(chain.calls).not.toContain("eth_sendRawTransaction");
  });

  test("selected mode leaves other people's due volumes alone", async () => {
    const chain = mockChain({ volumes: [due(1), due(2)] });
    const { client } = chain;
    const result = await runKeeperCycle(client, {
      registry: REGISTRY,
      mode: { type: "selected", volumeIds: [volumeId(1)] },
    });

    expect(result.mode).toBe("selected");
    expect(chain.triggerCalls).toEqual([[volumeId(1)]]);
  });
});

describe("decorators", () => {
  test("volumeRegistryActions binds the registry to read actions", async () => {
    const { client: base } = mockChain({ volumes: [funded(1), due(2)] });
    const client = base.extend(volumeRegistryActions({ registry: REGISTRY }));

    expect(await client.getActiveVolumeCount()).toBe(2n);
    expect(await client.getRegistryConfig()).toEqual({
      postage: POSTAGE,
      graceBlocks: GRACE,
    });
    expect((await client.getKeeperPlan()).due).toHaveLength(1);
    expect(await client.getVolume({ volumeId: volumeId(1) })).toMatchObject({
      status: 1,
    });
  });

  test("keeperActions binds the registry to write actions", async () => {
    const chain = mockChain({ volumes: [due(1)] });
    const base = chain.client;
    const client = base.extend(keeperActions({ registry: REGISTRY }));

    const result = await client.runKeeperCycle();
    expect(result.ok).toBe(true);
    expect(chain.triggerCalls).toEqual([[volumeId(1)]]);
  });

  test("both decorators compose on one client", async () => {
    const { client: base } = mockChain({ volumes: [due(1)] });
    const client = base
      .extend(volumeRegistryActions({ registry: REGISTRY }))
      .extend(keeperActions({ registry: REGISTRY }));

    const plan = await client.getKeeperPlan();
    const hash = await client.trigger({ volumeIds: plan.volumeIds });
    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
  });
});
