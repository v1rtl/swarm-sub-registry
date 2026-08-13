import { describe, expect, test } from "bun:test";
import { zeroAddress, type Address } from "viem";
import { chunk, triage, triggerIds, type BatchState, type ChainState } from "../src/triage.js";
import type { VolumeView } from "../src/types.js";

const SIGNER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OTHER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;

const STATE: ChainState = {
  lastPrice: 44_445n,
  graceBlocks: 17_280n,
  outPayment: 1_000_000n,
  timestamp: 1_700_000_000n,
};
const TARGET = STATE.lastPrice * STATE.graceBlocks;

const volume = (over: Partial<VolumeView> = {}): VolumeView => ({
  volumeId: "0x0000000000000000000000000000000000000000000000000000000000000001",
  owner: SIGNER,
  payer: SIGNER,
  chunkSigner: SIGNER,
  createdAt: 0n,
  ttlExpiry: 0n,
  depth: 20,
  status: 1,
  accountActive: true,
  ...over,
});

const batch = (over: Partial<BatchState> = {}): BatchState => ({
  owner: SIGNER,
  depth: 20,
  normalisedBalance: STATE.outPayment + TARGET * 2n,
  ...over,
});

/** Balance that leaves exactly `remaining` of runway. */
const withRemaining = (remaining: bigint) =>
  batch({ normalisedBalance: STATE.outPayment + remaining });

describe("triage", () => {
  test("a fully-funded volume is healthy and sends nothing", () => {
    const result = triage([volume()], [batch()], STATE);
    expect(result.healthy).toHaveLength(1);
    expect(triggerIds(result)).toEqual([]);
  });

  test("balance exactly at target is not due (mirrors the contract's >= check)", () => {
    const result = triage([volume()], [withRemaining(TARGET)], STATE);
    expect(result.healthy).toHaveLength(1);
    expect(result.due).toHaveLength(0);
  });

  test("one wei below target is due", () => {
    const result = triage([volume()], [withRemaining(TARGET - 1n)], STATE);
    expect(result.due).toHaveLength(1);
  });

  test("a missing batch is dead", () => {
    const result = triage([volume()], [batch({ owner: zeroAddress })], STATE);
    expect(result.dead[0]?.reason).toBe("batchMissing");
  });

  test("an absent batch entry is dead rather than a crash", () => {
    const result = triage([volume()], [undefined], STATE);
    expect(result.dead[0]?.reason).toBe("batchMissing");
  });

  test("a drained batch is dead", () => {
    const result = triage([volume()], [withRemaining(0n)], STATE);
    expect(result.dead[0]?.reason).toBe("batchExpired");
  });

  test("a batch owned by someone other than the chunk signer is dead", () => {
    const result = triage([volume()], [batch({ owner: OTHER })], STATE);
    expect(result.dead[0]?.reason).toBe("ownerMismatch");
  });

  // TEST-PLAN S6: the chunk signer calls PostageStamp.increaseDepth directly.
  test("a depth change retires the volume", () => {
    const result = triage([volume()], [batch({ depth: 21 })], STATE);
    expect(result.dead[0]?.reason).toBe("depthChanged");
  });

  // TEST-PLAN S4: gas-boy previously never checked TTL, so expired volumes
  // sat in the active index until someone called reap by hand.
  test("a passed TTL retires the volume even while it is fully funded", () => {
    const expired = volume({ ttlExpiry: STATE.timestamp - 1n });
    const result = triage([expired], [batch()], STATE);
    expect(result.dead[0]?.reason).toBe("ttlExpired");
    expect(triggerIds(result)).toEqual([expired.volumeId]);
  });

  test("ttlExpiry of zero means no expiry", () => {
    const result = triage([volume({ ttlExpiry: 0n })], [batch()], STATE);
    expect(result.dead).toHaveLength(0);
  });

  test("TTL is inclusive at the boundary, like the contract", () => {
    const result = triage([volume({ ttlExpiry: STATE.timestamp })], [batch()], STATE);
    expect(result.dead[0]?.reason).toBe("ttlExpired");
  });

  // TEST-PLAN S5: a revoked account must not be paid for, but must not be
  // retired either — the volume coasts on its remaining balance.
  test("an underfunded volume with no active account is reported, not sent", () => {
    const result = triage(
      [volume({ accountActive: false })],
      [withRemaining(1n)],
      STATE,
    );
    expect(result.noAuth).toHaveLength(1);
    expect(result.due).toHaveLength(0);
    expect(triggerIds(result)).toEqual([]);
  });

  test("a dead batch outranks a revoked account", () => {
    const result = triage(
      [volume({ accountActive: false })],
      [batch({ owner: zeroAddress })],
      STATE,
    );
    expect(result.dead).toHaveLength(1);
    expect(result.noAuth).toHaveLength(0);
  });

  test("a non-Active volume is treated as dead", () => {
    const result = triage([volume({ status: 2 })], [batch()], STATE);
    expect(result.dead).toHaveLength(1);
  });

  test("chunk signer comparison ignores address casing", () => {
    const mixed = volume({ chunkSigner: SIGNER.toUpperCase() as Address });
    const result = triage([mixed], [batch({ owner: SIGNER })], STATE);
    expect(result.dead).toHaveLength(0);
  });

  // TEST-PLAN S4: one healthy, one revoked, one expired, in a single pass.
  test("a mixed cycle classifies every volume independently", () => {
    const volumes = [
      volume({ volumeId: "0x01".padEnd(66, "0") as `0x${string}` }),
      volume({
        volumeId: "0x02".padEnd(66, "0") as `0x${string}`,
        accountActive: false,
      }),
      volume({
        volumeId: "0x03".padEnd(66, "0") as `0x${string}`,
        ttlExpiry: STATE.timestamp - 1n,
      }),
      volume({ volumeId: "0x04".padEnd(66, "0") as `0x${string}` }),
    ];
    const result = triage(
      volumes,
      [batch(), withRemaining(1n), batch(), withRemaining(1n)],
      STATE,
    );

    expect(result.healthy).toHaveLength(1);
    expect(result.noAuth).toHaveLength(1);
    expect(result.dead).toHaveLength(1);
    expect(result.due).toHaveLength(1);
  });

  test("top-ups are ordered ahead of cleanup", () => {
    const due = volume({ volumeId: "0x0a".padEnd(66, "0") as `0x${string}` });
    const dead = volume({ volumeId: "0x0b".padEnd(66, "0") as `0x${string}` });
    const result = triage([dead, due], [batch({ owner: zeroAddress }), withRemaining(1n)], STATE);
    expect(triggerIds(result)).toEqual([due.volumeId, dead.volumeId]);
  });

  test("an empty registry triages to nothing", () => {
    const result = triage([], [], STATE);
    expect(triggerIds(result)).toEqual([]);
  });
});

describe("chunk", () => {
  test("splits preserving order", () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
  });

  test("a short list stays whole", () => {
    expect(chunk([1, 2], 50)).toEqual([[1, 2]]);
  });

  test("an empty list yields no chunks", () => {
    expect(chunk([], 10)).toEqual([]);
  });

  test("rejects a zero size instead of looping forever", () => {
    expect(() => chunk([1], 0)).toThrow();
  });
});
