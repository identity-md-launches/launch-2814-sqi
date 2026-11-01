import {
  BaseError,
  ContractFunctionRevertedError,
  formatUnits,
  parseUnits,
} from "viem";

export const DURATIONS = [6, 12, 24, 144] as const;
export const THRESHOLDS = [3000, 5000, 7000] as const;
const MAX_UINT256 = (1n << 256n) - 1n;
export function amount(value: string): bigint {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(value.trim()))
    throw new Error("Enter a positive amount with up to 18 decimal places.");
  const parsed = parseUnits(value.trim(), 18);
  if (parsed <= 0n || parsed > MAX_UINT256)
    throw new Error("Enter a positive amount within the token limit.");
  return parsed;
}
export function integer(
  value: string,
  label = "Policy ID",
  maximum = MAX_UINT256,
): bigint {
  if (!/^[1-9]\d*$/.test(value.trim()))
    throw new Error(
      `Enter a positive whole number for ${label.toLowerCase()}.`,
    );
  const parsed = BigInt(value.trim());
  if (parsed > maximum)
    throw new Error(`${label} is above the contract limit.`);
  return parsed;
}
export const fullAmount = (value: bigint) => formatUnits(value, 18);
export function displayAmount(value: bigint): string {
  if (value === 0n) return "0";
  if (value < 10n ** 14n) return "<0.0001";
  const [whole, fraction = ""] = fullAmount(value).split(".");
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}${fraction ? "." + fraction.slice(0, 4).replace(/0+$/, "") : ""}`.replace(
    /\.$/,
    "",
  );
}
export const requiredZeros = (rounds: number, thresholdBps: number) =>
  Math.ceil((rounds * thresholdBps) / 10000);
export const automaticStart = (frontier: bigint, current: bigint) =>
  (frontier > current ? frontier : current) + 2n;
export function validateStart(
  start: bigint,
  frontier: bigint,
  current: bigint,
  rounds: number,
) {
  if (start <= frontier || start <= current)
    throw new Error(
      "Choose a start round after both the current round and the frontier.",
    );
  if (start > current + 1008n)
    throw new Error("Start at most 1,008 rounds ahead of the current round.");
  if (start + BigInt(rounds) - 1n > (1n << 64n) - 1n)
    throw new Error("The end round exceeds the contract limit.");
}
export function minimumOutput(value: bigint): bigint {
  const minimum = (value * 995n) / 1000n;
  if (minimum <= 0n)
    throw new Error("This amount rounds to zero. Enter a larger amount.");
  return minimum;
}
export const shortAddress = (address: string) =>
  `${address.slice(0, 6)}…${address.slice(-4)}`;
const errors: Record<string, string> = {
  NotConfigured:
    "The pool is not bound to PolicyBook. Owner activation is required; check LAUNCH.md.",
  BookNotConfigured:
    "The pool is not activated. Owner binding is required before deposits.",
  RateNotConfigured:
    "This term has no configured premium rate. Try another term or wait for owner activation.",
  InsufficientLiquidity:
    "There is not enough free pool liquidity for this cover. Reduce the amount or wait for liquidity.",
  InsufficientFreeAssets:
    "Reserved cover cannot be redeemed. Reduce the shares or wait for policies to settle.",
  SettlementPending:
    "A certified policy needs settlement or review before LPs can move. Use the Settle panel.",
  OpeningPaused: "New COVER is paused. Try again after opening resumes.",
  CorePaused: "SqueekCore is paused. New COVER cannot open until it resumes.",
  StartNotFuture:
    "The start round is no longer in the future. Get a new quote.",
  StartTooFar:
    "Choose a start no more than 1,008 rounds ahead of the current round.",
  Undecided:
    "Certified history does not fix this outcome yet. Retry after the frontier advances, or review the policy.",
  UnknownRounds:
    "The frontier has not certified this window. Retry after it advances.",
  PolicyNotOpen:
    "This policy is missing or already settled. Look up its current status.",
  PremiumExceeded:
    "The premium increased beyond your maximum. Get a new quote.",
  DeadlineExpired: "The quote deadline passed. Get a new quote.",
  Slippage:
    "The pool output moved below your minimum. Preview again before retrying.",
  InsufficientShares:
    "Your wallet does not hold enough current-epoch shares. Refresh the balance.",
  ERC20InsufficientBalance:
    "Your wallet needs more mSQK (on-chain symbol SQI). Only the token owner can mint it.",
  ERC20InsufficientAllowance:
    "Token approval is insufficient. Approve the exact amount, then retry.",
  CoreUnavailable:
    "Core reads are unavailable. Refresh later; unknown rounds do not count as zero-work.",
  UnsupportedCoreVersion:
    "CoreReader rejects the Core version. Transactions are unavailable; inspect THREATS.md.",
  InvalidConfiguration:
    "CoreReader rejects the Core configuration. Transactions are unavailable; inspect THREATS.md.",
  ShareSupplyExhausted:
    "The pool cannot issue more shares at this supply. See the recapitalization limits in THREATS.md.",
};
export class DeadlineError extends Error {
  constructor(what: string, ms: number) {
    super(
      `${what} took longer than ${Math.round(ms / 1000)} seconds on every Sepolia RPC. Check your connection, then retry. Nothing was sent.`,
    );
    this.name = "DeadlineError";
  }
}
// Caps a read so no spinner outlives `ms`. The underlying request may still settle
// later; callers ignore it because the promise has already rejected.
export function withDeadline<T>(
  work: Promise<T>,
  ms: number,
  what: string,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    work,
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new DeadlineError(what, ms)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}
export function explainError(error: unknown): string {
  if (error instanceof DeadlineError) return error.message;
  if (error instanceof BaseError) {
    const reverted = error.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    );
    if (
      reverted instanceof ContractFunctionRevertedError &&
      reverted.data?.errorName
    ) {
      return (
        errors[reverted.data.errorName] ??
        `Contract rejected the action (${reverted.data.errorName}). Refresh the state and check the inputs.`
      );
    }
    if (/reject|denied/i.test(error.message))
      return "Request declined in your wallet. Nothing further was sent; you can try again.";
    if (/insufficient funds/i.test(error.message))
      return "Your wallet needs Sepolia ETH for gas. Fund it on Sepolia and retry.";
    if (/timeout|timed out|fetch|HTTP|network/i.test(error.message))
      return "Sepolia could not be reached. Check your connection and retry. If a transaction hash is shown, check it before resubmitting.";
    return `${error.shortMessage} Refresh and retry when ready.`;
  }
  return error instanceof Error
    ? error.message
    : "The action could not complete. Refresh and try again.";
}
