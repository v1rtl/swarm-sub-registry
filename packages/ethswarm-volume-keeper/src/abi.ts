// Minimal ABI surface of VolumeRegistry + PostageStamp that a keeper needs.
// Kept `as const` so viem can infer per-function argument and return types.
//
// Deliberately partial: this is a keeper, not a registry SDK. The singular
// `trigger(bytes32)` overload is omitted — the batched form covers a single
// id and keeping one signature keeps viem's overload inference simple.

export const registryAbi = [
  {
    type: "function",
    name: "getActiveVolumeCount",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getActiveVolumes",
    stateMutability: "view",
    inputs: [
      { type: "uint256", name: "offset" },
      { type: "uint256", name: "limit" },
    ],
    outputs: [
      {
        type: "tuple[]",
        name: "",
        components: [
          { name: "volumeId", type: "bytes32" },
          { name: "owner", type: "address" },
          { name: "payer", type: "address" },
          { name: "chunkSigner", type: "address" },
          { name: "createdAt", type: "uint64" },
          { name: "ttlExpiry", type: "uint64" },
          { name: "depth", type: "uint8" },
          { name: "status", type: "uint8" },
          { name: "accountActive", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getVolume",
    stateMutability: "view",
    inputs: [{ type: "bytes32", name: "volumeId" }],
    outputs: [
      {
        type: "tuple",
        name: "",
        components: [
          { name: "volumeId", type: "bytes32" },
          { name: "owner", type: "address" },
          { name: "payer", type: "address" },
          { name: "chunkSigner", type: "address" },
          { name: "createdAt", type: "uint64" },
          { name: "ttlExpiry", type: "uint64" },
          { name: "depth", type: "uint8" },
          { name: "status", type: "uint8" },
          { name: "accountActive", type: "bool" },
        ],
      },
    ],
  },
  // Constructor-immutable wiring, read once and cached: the PostageStamp
  // address is discovered here rather than configured.
  {
    type: "function",
    name: "postage",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "graceBlocks",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "trigger",
    stateMutability: "nonpayable",
    inputs: [{ type: "bytes32[]", name: "volumeIds" }],
    outputs: [],
  },
  {
    type: "function",
    name: "reap",
    stateMutability: "nonpayable",
    inputs: [{ type: "bytes32", name: "volumeId" }],
    outputs: [],
  },
  // Events decoded off the trigger receipt to explain per-volume outcomes.
  {
    type: "event",
    name: "Toppedup",
    inputs: [
      { indexed: true, type: "bytes32", name: "volumeId" },
      { indexed: false, type: "uint256", name: "amount" },
      { indexed: false, type: "uint256", name: "newNormalisedBalance" },
    ],
  },
  {
    type: "event",
    name: "TopupSkipped",
    inputs: [
      { indexed: true, type: "bytes32", name: "volumeId" },
      { indexed: false, type: "uint8", name: "reason" },
    ],
  },
  {
    type: "event",
    name: "VolumeRetired",
    inputs: [
      { indexed: true, type: "bytes32", name: "volumeId" },
      { indexed: false, type: "uint8", name: "reason" },
    ],
  },
] as const;

// PostageStamp subset — feeds the client-side due/dead triage.
export const postageAbi = [
  {
    type: "function",
    name: "batches",
    stateMutability: "view",
    inputs: [{ type: "bytes32", name: "id" }],
    outputs: [
      { type: "address", name: "owner" },
      { type: "uint8", name: "depth" },
      { type: "uint8", name: "bucketDepth" },
      { type: "bool", name: "immutableFlag" },
      { type: "uint256", name: "normalisedBalance" },
      { type: "uint256", name: "lastUpdatedBlockNumber" },
    ],
  },
  {
    type: "function",
    name: "currentTotalOutPayment",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "lastPrice",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
] as const;

/** Volume.status values (VolumeRegistry.sol). */
export const VOLUME_STATUS = { active: 1, retired: 2 } as const;

/** `VolumeRetired(volumeId, reason)` reason codes, decoded to names. */
export const RETIRE_REASONS: Record<number, string> = {
  1: "OwnerDeleted",
  2: "VolumeExpired",
  3: "BatchDied",
  4: "DepthChanged",
  5: "BatchOwnerMismatch",
};

/** `TopupSkipped(volumeId, reason)` reason codes, decoded to names. */
export const SKIP_REASONS: Record<number, string> = {
  1: "NoAuth",
  2: "PaymentFailed",
};
