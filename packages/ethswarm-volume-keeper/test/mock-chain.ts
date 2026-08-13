/**
 * An in-memory VolumeRegistry + PostageStamp behind a viem `custom` transport.
 *
 * Enough of the JSON-RPC surface to drive a whole keeper cycle — multicall
 * reads, estimate, sign, send, receipt — so the wiring is exercised end to end
 * without anvil. Contract *semantics* are covered by the Foundry suite; what
 * these fixtures prove is that the keeper reads, triages and sends the right
 * things.
 */
import {
  createWalletClient,
  custom,
  decodeFunctionData,
  publicActions,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  keccak256,
  multicall3Abi,
  numberToHex,
  parseTransaction,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { postageAbi, registryAbi } from "../src/abi.js";

const MULTICALL3 = sepolia.contracts.multicall3.address;
export const REGISTRY = "0x1111111111111111111111111111111111111111" as const;
export const POSTAGE = "0x2222222222222222222222222222222222222222" as const;
const SIGNER = "0x3333333333333333333333333333333333333333" as const;

/** anvil account #1 — a well-known throwaway key, test fixtures only. */
const TEST_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;

export interface MockVolume {
  volumeId: Hex;
  owner?: Address;
  chunkSigner?: Address;
  ttlExpiry?: bigint;
  depth?: number;
  status?: number;
  accountActive?: boolean;
  /** Omit to model a batch that does not exist on PostageStamp. */
  batch?: { owner?: Address; depth?: number; normalisedBalance: bigint };
}

export interface MockChainOptions {
  volumes?: MockVolume[];
  graceBlocks?: bigint;
  lastPrice?: bigint;
  outPayment?: bigint;
  blockNumber?: bigint;
  timestamp?: bigint;
  balance?: bigint;
  /** What eth_estimateGas returns. Default 500_000. */
  estimateGas?: bigint;
  /** Fail every RPC request with this message. */
  failWith?: string;
  /** Mark sent transactions as reverted. */
  revertTx?: boolean;
  /** Never return a receipt, to model a stuck transaction. */
  dropReceipts?: boolean;
}

/**
 * A real node answers an unknown method with JSON-RPC `-32601`, which viem
 * recognises as "not supported", caches, and does not retry. Throwing a plain
 * Error instead makes viem re-probe optional methods (`eth_fillTransaction`)
 * with backoff on every transaction.
 */
class MethodNotFound extends Error {
  readonly code = -32601;
  constructor(method: string) {
    super(`the method ${method} does not exist/is not available`);
  }
}

const volumeTuple = (v: MockVolume) => ({
  volumeId: v.volumeId,
  owner: v.owner ?? SIGNER,
  payer: v.owner ?? SIGNER,
  chunkSigner: v.chunkSigner ?? SIGNER,
  createdAt: 0n,
  ttlExpiry: v.ttlExpiry ?? 0n,
  depth: v.depth ?? 20,
  status: v.status ?? 1,
  accountActive: v.accountActive ?? true,
});

export function mockChain(options: MockChainOptions = {}) {
  const volumes = options.volumes ?? [];
  const graceBlocks = options.graceBlocks ?? 17280n;
  const lastPrice = options.lastPrice ?? 44445n;
  const outPayment = options.outPayment ?? 1_000_000n;
  const blockNumber = options.blockNumber ?? 8_000_000n;
  const timestamp = options.timestamp ?? 1_700_000_000n;

  const triggerCalls: Hex[][] = [];
  const sentGas: bigint[] = [];
  const calls: string[] = [];
  const receipts = new Map<Hex, { ids: Hex[] }>();
  let multicallCount = 0;

  function callRegistry(data: Hex): Hex {
    const { functionName, args } = decodeFunctionData({ abi: registryAbi, data });
    switch (functionName) {
      case "postage":
        return encodeFunctionResult({ abi: registryAbi, functionName, result: POSTAGE });
      case "graceBlocks":
        return encodeFunctionResult({ abi: registryAbi, functionName, result: graceBlocks });
      case "getActiveVolumeCount":
        return encodeFunctionResult({
          abi: registryAbi,
          functionName,
          result: BigInt(volumes.length),
        });
      case "getActiveVolumes": {
        const [offset, limit] = args as readonly [bigint, bigint];
        const page = volumes
          .slice(Number(offset), Number(offset) + Number(limit))
          .map(volumeTuple);
        return encodeFunctionResult({ abi: registryAbi, functionName, result: page });
      }
      case "getVolume": {
        const [id] = args as readonly [Hex];
        const found = volumes.find((v) => v.volumeId.toLowerCase() === id.toLowerCase());
        const view = found
          ? volumeTuple(found)
          : {
              volumeId: id,
              owner: zeroAddress,
              payer: zeroAddress,
              chunkSigner: zeroAddress,
              createdAt: 0n,
              ttlExpiry: 0n,
              depth: 0,
              status: 0,
              accountActive: false,
            };
        return encodeFunctionResult({ abi: registryAbi, functionName, result: view });
      }
      case "trigger":
      case "reap":
        return "0x";
      default:
        throw new Error(`mock registry: unhandled ${functionName}`);
    }
  }

  function callPostage(data: Hex): Hex {
    const { functionName, args } = decodeFunctionData({ abi: postageAbi, data });
    switch (functionName) {
      case "lastPrice":
        return encodeFunctionResult({ abi: postageAbi, functionName, result: lastPrice });
      case "currentTotalOutPayment":
        return encodeFunctionResult({ abi: postageAbi, functionName, result: outPayment });
      case "batches": {
        const [id] = args as readonly [Hex];
        const found = volumes.find((v) => v.volumeId.toLowerCase() === id.toLowerCase());
        const batch = found?.batch;
        return encodeFunctionResult({
          abi: postageAbi,
          functionName,
          result: batch
            ? [
                batch.owner ?? found?.chunkSigner ?? SIGNER,
                batch.depth ?? found?.depth ?? 20,
                16,
                false,
                batch.normalisedBalance,
                0n,
              ]
            : [zeroAddress, 0, 0, false, 0n, 0n],
        });
      }
      default:
        throw new Error(`mock postage: unhandled ${functionName}`);
    }
  }

  function dispatch(to: Address, data: Hex): Hex {
    const target = to.toLowerCase();
    if (target === REGISTRY.toLowerCase()) return callRegistry(data);
    if (target === POSTAGE.toLowerCase()) return callPostage(data);
    throw new Error(`mock chain: no contract at ${to}`);
  }

  function handleCall(tx: { to: Address; data: Hex }): Hex {
    if (tx.to.toLowerCase() !== MULTICALL3.toLowerCase()) return dispatch(tx.to, tx.data);

    multicallCount += 1;
    const { args } = decodeFunctionData({ abi: multicall3Abi, data: tx.data });
    const batch = (args as readonly [readonly { target: Address; callData: Hex }[]])[0];
    const results = batch.map((call) => {
      try {
        return { success: true, returnData: dispatch(call.target, call.callData) };
      } catch {
        return { success: false, returnData: "0x" as Hex };
      }
    });
    return encodeFunctionResult({
      abi: multicall3Abi,
      functionName: "aggregate3",
      result: results,
    });
  }

  /** One `Toppedup` per id, so receipt decoding has something to chew on. */
  function receiptLogs(ids: Hex[]) {
    return ids.map((volumeId, i) => ({
      address: REGISTRY,
      topics: encodeEventTopics({
        abi: registryAbi,
        eventName: "Toppedup",
        args: { volumeId },
      }),
      data: encodeAbiParameters(
        [{ type: "uint256" }, { type: "uint256" }],
        [1000n, 2000n],
      ),
      blockNumber: numberToHex(blockNumber),
      blockHash: keccak256(toHex("block")),
      transactionHash: keccak256(toHex("tx")),
      transactionIndex: "0x0",
      logIndex: numberToHex(i),
      removed: false,
    }));
  }

  const transport = custom({
    async request({ method, params }: { method: string; params?: unknown }) {
      calls.push(method);
      if (options.failWith) throw new Error(options.failWith);
      const args = (params ?? []) as unknown[];

      switch (method) {
        case "eth_chainId":
          return numberToHex(sepolia.id);
        case "eth_blockNumber":
          return numberToHex(blockNumber);
        case "eth_getBlockByNumber":
        case "eth_getBlockByHash":
          return {
            number: numberToHex(blockNumber),
            timestamp: numberToHex(timestamp),
            hash: keccak256(toHex("block")),
            parentHash: keccak256(toHex("parent")),
            baseFeePerGas: numberToHex(1_000_000_000n),
            gasLimit: numberToHex(30_000_000n),
            gasUsed: "0x0",
            transactions: [],
          };
        case "eth_call":
          return handleCall(args[0] as { to: Address; data: Hex });
        case "eth_estimateGas":
          return numberToHex(options.estimateGas ?? 500_000n);
        case "eth_getBalance":
          return numberToHex(options.balance ?? 10n ** 18n);
        case "eth_getTransactionCount":
          return numberToHex(BigInt(triggerCalls.length));
        case "eth_gasPrice":
          return numberToHex(1_500_000_000n);
        case "eth_maxPriorityFeePerGas":
          return numberToHex(1_000_000n);
        case "eth_sendRawTransaction": {
          const { data, gas } = parseTransaction(args[0] as Hex);
          sentGas.push(gas ?? 0n);
          const { args: callArgs } = decodeFunctionData({
            abi: registryAbi,
            data: data as Hex,
          });
          const ids = (callArgs as readonly [readonly Hex[]])[0] as Hex[];
          triggerCalls.push(ids);
          const hash = keccak256(toHex(`tx-${triggerCalls.length}`));
          receipts.set(hash, { ids });
          return hash;
        }
        case "eth_getTransactionReceipt": {
          const hash = args[0] as Hex;
          const sent = receipts.get(hash);
          if (!sent || options.dropReceipts) return null;
          return {
            transactionHash: hash,
            transactionIndex: "0x0",
            blockNumber: numberToHex(blockNumber),
            blockHash: keccak256(toHex("block")),
            from: SIGNER,
            to: REGISTRY,
            cumulativeGasUsed: numberToHex(400_000n),
            gasUsed: numberToHex(400_000n),
            effectiveGasPrice: numberToHex(1_500_000_000n),
            contractAddress: null,
            status: options.revertTx ? "0x0" : "0x1",
            type: "0x2",
            logs: options.revertTx ? [] : receiptLogs(sent.ids),
            logsBloom: `0x${"0".repeat(512)}`,
          };
        }
        default:
          throw new MethodNotFound(method);
      }
    },
  });

  const client = createWalletClient({
    account: privateKeyToAccount(TEST_KEY),
    chain: sepolia,
    transport,
    // The mock answers instantly; viem's 4s default would dominate every
    // receipt wait.
    pollingInterval: 10,
  }).extend(publicActions);

  return {
    client,
    triggerCalls,
    /** Gas limit carried by each transaction actually sent. */
    sentGas,
    calls,
    get multicallCount() {
      return multicallCount;
    },
  };
}

/** Deterministic 32-byte volume id. */
export const volumeId = (n: number): Hex =>
  `0x${n.toString(16).padStart(64, "0")}` as Hex;
