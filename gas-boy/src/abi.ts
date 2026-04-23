// Minimal ABI surface of VolumeRegistry that gas-boy needs. Kept as
// `as const` so viem can infer per-function return types.
//
// Target contract: the rewritten VolumeRegistry per notes/DESIGN.md.
// The old keepalive()/pruneDead()/isDue()/isDead() surface is gone —
// the new API is:
//   - getActiveVolumeCount() view
//   - getActiveVolumes(offset, limit) view → VolumeView[]
//   - trigger(bytes32[]) — batched, per-item try/catch inside the contract
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
  // Events we care about for log decoding.
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

// PostageStamp subset — used by the client-side due/dead filter.
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
