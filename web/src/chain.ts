import { keccak256, type Abi, type Address, type Hex } from "viem";
import {
  abis,
  addresses,
  chain,
  publicClient,
  type ContractName,
} from "./config";
import runtime from "./runtime.json";
import { explainError } from "./domain";

const errors = Object.values(abis).flatMap((abi) =>
  abi.filter((item) => item.type === "error"),
);
export const contractAbi = (name: ContractName): Abi =>
  [...abis[name], ...errors] as Abi;
export async function read<T>(
  name: ContractName,
  functionName: string,
  args: readonly unknown[] = [],
  blockNumber?: bigint,
): Promise<T> {
  return (await publicClient.readContract({
    address: addresses[name],
    abi: contractAbi(name),
    functionName,
    args,
    blockNumber,
  })) as T;
}
export interface Snapshot {
  block: bigint;
  timestamp: bigint;
  fetchedAt: number;
  frontier?: bigint;
  current?: bigint;
  corePaused?: boolean;
  assets?: bigint;
  reserved?: bigint;
  free?: bigint;
  open?: bigint;
  nextId?: bigint;
  paused?: boolean;
  configured?: boolean;
  pending?: boolean;
  decide?: bigint;
  errors: string[];
}
export async function fetchSnapshot(): Promise<Snapshot> {
  if ((await publicClient.getChainId()) !== chain.id)
    throw new Error(
      "The public RPC returned the wrong chain. Reads and transactions are unavailable.",
    );
  const block = await publicClient.getBlock();
  const result: Snapshot = {
    block: block.number,
    timestamp: block.timestamp,
    fetchedAt: Date.now(),
    errors: [],
  };
  const reads: [string, Promise<unknown>, (value: unknown) => void][] = [
    [
      "Core",
      read<readonly [bigint, bigint, boolean]>(
        "CoreReader",
        "snapshot",
        [],
        block.number,
      ),
      (value) => {
        [result.frontier, result.current, result.corePaused] = value as [
          bigint,
          bigint,
          boolean,
        ];
      },
    ],
    ...(
      [
        ["assets", "CoverPool", "totalAssets"],
        ["reserved", "CoverPool", "reserved"],
        ["free", "CoverPool", "freeAssets"],
        ["open", "PolicyBook", "openPolicyCount"],
        ["nextId", "PolicyBook", "nextPolicyId"],
        ["decide", "PolicyBook", "earliestDecideRound"],
      ] as const
    ).map(
      ([key, name, fn]): [
        string,
        Promise<unknown>,
        (value: unknown) => void,
      ] => [
        key,
        read<bigint>(name, fn, [], block.number),
        (value) => {
          result[key] = value as bigint;
        },
      ],
    ),
    [
      "Opening pause",
      read<boolean>("PolicyBook", "paused", [], block.number),
      (value) => {
        result.paused = value as boolean;
      },
    ],
    [
      "Pool binding",
      read<Address>("CoverPool", "policyBook", [], block.number),
      (value) => {
        result.configured =
          String(value).toLowerCase() === addresses.PolicyBook;
      },
    ],
    [
      "Settlement gate",
      read<boolean>("PolicyBook", "settlementPending", [], block.number),
      (value) => {
        result.pending = value as boolean;
      },
    ],
  ];
  const outcomes = await Promise.allSettled(
    reads.map(([, promise]) => promise),
  );
  outcomes.forEach((outcome, i) => {
    if (outcome.status === "fulfilled") reads[i][2](outcome.value);
    else result.errors.push(`${reads[i][0]}: ${explainError(outcome.reason)}`);
  });
  return result;
}

// Check the deployed runtime against the compiler output, ignoring immutable slots,
// then check every immutable dependency by its getter. No remote ABI is trusted.
export async function verifyDeployment(): Promise<{ block: bigint }> {
  if ((await publicClient.getChainId()) !== chain.id)
    throw new Error(
      "Deployment verification failed: the RPC is not on Sepolia.",
    );
  const block = await publicClient.getBlockNumber({ cacheTime: 0 });
  await Promise.all(
    Object.entries(runtime).map(async ([name, expected]) => {
      const code = await publicClient.getCode({
        address: addresses[name as ContractName],
        blockNumber: block,
      });
      if (!code || (code.length - 2) / 2 !== expected.byteLength)
        throw new Error(
          `${name} runtime does not match the pinned deployment. Wallet actions are blocked.`,
        );
      let normalized = code.slice(2);
      for (const reference of expected.immutableReferences) {
        normalized =
          normalized.slice(0, reference.start * 2) +
          "0".repeat(reference.length * 2) +
          normalized.slice((reference.start + reference.length) * 2);
      }
      if (keccak256(`0x${normalized}`) !== expected.normalizedHash)
        throw new Error(
          `${name} code differs from the pinned source. Wallet actions are blocked.`,
        );
    }),
  );
  const graph: [ContractName, string, Address][] = [
    ["PolicyBook", "token", addresses.MockSQK],
    ["PolicyBook", "pool", addresses.CoverPool],
    ["PolicyBook", "reader", addresses.CoreReader],
    ["PolicyBook", "premiumModel", addresses.PremiumModel],
    ["CoverPool", "token", addresses.MockSQK],
    ["CoreReader", "core", addresses.SqueekCore],
  ];
  await Promise.all(
    graph.map(async ([name, getter, expected]) => {
      const actual = await read<Address>(name, getter, [], block);
      if (actual.toLowerCase() !== expected.toLowerCase())
        throw new Error(
          `${name}.${getter} differs from the deployment. Wallet actions are blocked.`,
        );
    }),
  );
  const [coreCode, decimals] = await Promise.all([
    publicClient.getCode({ address: addresses.SqueekCore, blockNumber: block }),
    read<number>("MockSQK", "decimals", [], block),
  ]);
  if (!coreCode || coreCode === "0x" || decimals !== 18)
    throw new Error(
      "Core code or collateral decimals failed deployment verification.",
    );
  return { block };
}

export interface Policy {
  holder: Address;
  startRound: bigint;
  endRound: bigint;
  decideRound: bigint;
  rounds: number;
  thresholdBps: number;
  zeroRounds: number;
  status: number;
  cover: bigint;
  premium: bigint;
}
export async function fetchPolicies(
  before: bigint,
  size = 5,
): Promise<{ id: bigint; policy: Policy }[]> {
  const ids = Array.from(
    {
      length: Number(
        before > BigInt(size) ? BigInt(size) : before > 1n ? before - 1n : 0n,
      ),
    },
    (_, i) => before - BigInt(i) - 1n,
  ).filter((id) => id > 0n);
  return await Promise.all(
    ids.map(async (id) => ({
      id,
      policy: await read<Policy>("PolicyBook", "getPolicy", [id]),
    })),
  );
}
export const transactionRequest = (
  name: ContractName,
  functionName: string,
  args: readonly unknown[],
  account: Address,
) => ({
  address: addresses[name],
  abi: contractAbi(name),
  functionName,
  args,
  account,
  chain,
});
export type TxRecord = {
  hash: Hex;
  label: string;
  state: "pending" | "confirmed" | "reverted" | "unknown";
};
