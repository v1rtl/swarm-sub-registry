// Minimal ABI surface of VolumeRegistry that gas-boy needs. Kept as
// `as const` so viem can infer return types per `functionName`.
export const registryAbi = [
  {
    type: "function",
    name: "keepalive",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "keepaliveOne",
    stateMutability: "nonpayable",
    inputs: [{ type: "bytes32", name: "id" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "pruneOne",
    stateMutability: "nonpayable",
    inputs: [{ type: "bytes32", name: "id" }],
    outputs: [],
  },
  {
    type: "function",
    name: "pruneDead",
    stateMutability: "nonpayable",
    inputs: [{ type: "bytes32[]", name: "ids" }],
    outputs: [],
  },
  {
    type: "function",
    name: "volumeCount",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "batchIds",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "isDue",
    stateMutability: "view",
    inputs: [{ type: "bytes32", name: "id" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "isDead",
    stateMutability: "view",
    inputs: [{ type: "bytes32", name: "id" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "event",
    name: "KeptAlive",
    inputs: [
      { indexed: true, name: "caller", type: "address" },
      { indexed: true, name: "batchId", type: "bytes32" },
      { indexed: true, name: "payer", type: "address" },
      { indexed: false, name: "perChunk", type: "uint256" },
      { indexed: false, name: "totalAmount", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "KeepaliveSkipped",
    inputs: [
      { indexed: true, name: "batchId", type: "bytes32" },
      { indexed: false, name: "reason", type: "bytes" },
    ],
  },
  {
    type: "event",
    name: "Pruned",
    inputs: [
      { indexed: true, name: "batchId", type: "bytes32" },
      { indexed: true, name: "caller", type: "address" },
    ],
  },
  {
    type: "event",
    name: "PruneSkipped",
    inputs: [
      { indexed: true, name: "batchId", type: "bytes32" },
      { indexed: false, name: "reason", type: "bytes" },
    ],
  },
] as const;
