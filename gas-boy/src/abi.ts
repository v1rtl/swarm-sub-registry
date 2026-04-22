// Minimal ABI surface of SubscriptionRegistry that gas-boy needs.
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
    name: "subscriptionCount",
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
    type: "event",
    name: "KeptAlive",
    inputs: [
      { indexed: true, name: "caller", type: "address" },
      { indexed: true, name: "batchId", type: "bytes32" },
      { indexed: true, name: "payer", type: "address" },
      { indexed: false, name: "topUpPerChunk", type: "uint256" },
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
] as const;
