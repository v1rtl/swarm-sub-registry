import {
  createPublicClient,
  http,
  type Hex,
  type PublicClient,
  type Chain,
  erc20Abi,
} from "viem";
import { sepolia, foundry } from "viem/chains";
import { registryAbi, postageAbi } from "./abi";
import type { Env, VolumeView, EnrichedVolume } from "./types";

const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const ZERO = "0x0000000000000000000000000000000000000000" as Hex;
const PAGE_SIZE = 100;

function buildChain(env: Env): Chain {
  const id = Number(env.CHAIN_ID);
  const base = id === 11155111 ? sepolia : id === 31337 ? foundry : null;
  if (!base) throw new Error(`unsupported CHAIN_ID: ${env.CHAIN_ID}`);
  return {
    ...base,
    rpcUrls: { default: { http: [env.RPC_URL] } },
    contracts: { ...base.contracts, multicall3: { address: MULTICALL3 } },
  };
}

export function createClient(env: Env): PublicClient {
  const chain = buildChain(env);
  return createPublicClient({ chain, transport: http(env.RPC_URL) });
}

export async function collectActiveVolumes(
  client: PublicClient,
  registry: Hex,
): Promise<VolumeView[]> {
  const total = Number(
    await client.readContract({
      address: registry,
      abi: registryAbi,
      functionName: "getActiveVolumeCount",
    }),
  );
  if (total === 0) return [];

  const pageCount = Math.ceil(total / PAGE_SIZE);
  const pages = await Promise.all(
    Array.from({ length: pageCount }, (_, i) =>
      client.readContract({
        address: registry,
        abi: registryAbi,
        functionName: "getActiveVolumes",
        args: [BigInt(i * PAGE_SIZE), BigInt(PAGE_SIZE)],
      }),
    ),
  );
  return pages.flat() as unknown as VolumeView[];
}

// Returns enriched volumes that belong to `address` (as owner or payer).
export async function getVolumesForAddress(
  client: PublicClient,
  env: Env,
  address: Hex,
): Promise<EnrichedVolume[]> {
  const volumes = await collectActiveVolumes(client, env.REGISTRY_ADDRESS);
  const matched = volumes.filter(
    (v) =>
      v.owner.toLowerCase() === address.toLowerCase() ||
      v.payer.toLowerCase() === address.toLowerCase(),
  );
  if (matched.length === 0) return [];

  const base = [
    { address: env.POSTAGE_ADDRESS, abi: postageAbi, functionName: "lastPrice" } as const,
    { address: env.REGISTRY_ADDRESS, abi: registryAbi, functionName: "graceBlocks" } as const,
    {
      address: env.POSTAGE_ADDRESS,
      abi: postageAbi,
      functionName: "currentTotalOutPayment",
    } as const,
  ];
  const batchReads = matched.map(
    (v) =>
      ({
        address: env.POSTAGE_ADDRESS,
        abi: postageAbi,
        functionName: "batches",
        args: [v.volumeId],
      }) as const,
  );

  const results = await client.multicall({
    contracts: [...base, ...batchReads],
    allowFailure: false,
  });

  const lastPrice = results[0] as unknown as bigint;
  const graceBlocks = results[1] as unknown as bigint;
  const outpayment = results[2] as unknown as bigint;
  const target = lastPrice * graceBlocks;

  const enriched: EnrichedVolume[] = [];
  for (let i = 0; i < matched.length; i++) {
    const v = matched[i]!;
    const batch = results[3 + i] as unknown as readonly [Hex, number, number, boolean, bigint, bigint];
    const normalisedBalance = batch[4];
    const remaining =
      normalisedBalance > outpayment ? normalisedBalance - outpayment : 0n;
    enriched.push({
      volumeId: v.volumeId,
      owner: v.owner,
      payer: v.payer,
      depth: v.depth,
      status: v.status,
      remaining,
      target,
      lastPrice,
      graceBlocks,
    });
  }
  return enriched;
}

export async function getBzzBalance(
  client: PublicClient,
  bzzAddress: Hex,
  account: Hex,
): Promise<bigint> {
  return (await client.readContract({
    address: bzzAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account],
  })) as bigint;
}

// Fetch recent TopupSkipped events for given volume IDs.
// Returns volumeIds that had reason=2 (SKIP_PAYMENT_FAILED).
export async function getRecentPaymentFailures(
  client: PublicClient,
  registry: Hex,
  fromBlock: bigint,
): Promise<Set<Hex>> {
  const logs = await client.getLogs({
    address: registry,
    event: {
      type: "event",
      name: "TopupSkipped",
      inputs: [
        { indexed: true, type: "bytes32", name: "volumeId" },
        { indexed: false, type: "uint8", name: "reason" },
      ],
    },
    fromBlock,
  });

  const failed = new Set<Hex>();
  for (const log of logs) {
    if (log.args.reason === 2) {
      failed.add(log.args.volumeId as Hex);
    }
  }
  return failed;
}
