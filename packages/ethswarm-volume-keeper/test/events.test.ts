import { describe, expect, test } from "bun:test";
import {
  encodeAbiParameters,
  encodeEventTopics,
  keccak256,
  toHex,
  type Address,
  type Hex,
  type Log,
} from "viem";
import { registryAbi } from "../src/abi.js";
import { decodeCycleEvents } from "../src/events.js";
import { REGISTRY, volumeId } from "./mock-chain.js";

const OTHER_CONTRACT = "0x9999999999999999999999999999999999999999" as Address;

const log = (
  eventName: "Toppedup" | "TopupSkipped" | "VolumeRetired",
  volume: Hex,
  data: Hex,
  address: Address = REGISTRY,
): Log =>
  ({
    address,
    topics: encodeEventTopics({
      abi: registryAbi,
      eventName,
      args: { volumeId: volume },
    }),
    data,
    blockNumber: 1n,
    blockHash: keccak256(toHex("b")),
    transactionHash: keccak256(toHex("t")),
    transactionIndex: 0,
    logIndex: 0,
    removed: false,
  }) as Log;

const uint8 = (n: number) => encodeAbiParameters([{ type: "uint8" }], [n]);
const topup = (amount: bigint) =>
  encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [amount, 42n]);

describe("decodeCycleEvents", () => {
  test("a successful top-up reports its amount", () => {
    const decoded = decodeCycleEvents(
      [log("Toppedup", volumeId(1), topup(5000n))],
      REGISTRY,
    );
    expect(decoded.toppedUp).toEqual([{ volumeId: volumeId(1), amount: 5000n }]);
  });

  test("skip reasons are named, not left as numbers", () => {
    const decoded = decodeCycleEvents(
      [
        log("TopupSkipped", volumeId(1), uint8(1)),
        log("TopupSkipped", volumeId(2), uint8(2)),
      ],
      REGISTRY,
    );
    expect(decoded.topupSkipped).toEqual([
      { volumeId: volumeId(1), reason: "NoAuth" },
      { volumeId: volumeId(2), reason: "PaymentFailed" },
    ]);
  });

  test("every retire reason the contract can emit is named", () => {
    const decoded = decodeCycleEvents(
      [1, 2, 3, 4, 5].map((reason) =>
        log("VolumeRetired", volumeId(reason), uint8(reason)),
      ),
      REGISTRY,
    );
    expect(decoded.retired.map((r) => r.reason)).toEqual([
      "OwnerDeleted",
      "VolumeExpired",
      "BatchDied",
      "DepthChanged",
      "BatchOwnerMismatch",
    ]);
  });

  test("an unrecognised reason code survives as-is", () => {
    const decoded = decodeCycleEvents(
      [log("VolumeRetired", volumeId(1), uint8(9))],
      REGISTRY,
    );
    expect(decoded.retired[0]?.reason).toBe("Unknown(9)");
  });

  test("logs from other contracts are ignored", () => {
    const decoded = decodeCycleEvents(
      [log("Toppedup", volumeId(1), topup(1n), OTHER_CONTRACT)],
      REGISTRY,
    );
    expect(decoded.toppedUp).toEqual([]);
  });

  test("the registry address is matched case-insensitively", () => {
    const decoded = decodeCycleEvents(
      [log("Toppedup", volumeId(1), topup(1n), REGISTRY.toUpperCase() as Address)],
      REGISTRY,
    );
    expect(decoded.toppedUp).toHaveLength(1);
  });

  test("a mixed receipt is split by outcome", () => {
    const decoded = decodeCycleEvents(
      [
        log("Toppedup", volumeId(1), topup(100n)),
        log("TopupSkipped", volumeId(2), uint8(1)),
        log("VolumeRetired", volumeId(3), uint8(2)),
      ],
      REGISTRY,
    );
    expect(decoded.toppedUp).toHaveLength(1);
    expect(decoded.topupSkipped).toHaveLength(1);
    expect(decoded.retired).toHaveLength(1);
  });

  test("an empty receipt decodes to nothing", () => {
    expect(decodeCycleEvents([], REGISTRY)).toEqual({
      toppedUp: [],
      retired: [],
      topupSkipped: [],
    });
  });
});
