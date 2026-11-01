import {
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { useConnection } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { decodeEventLog } from "viem";
import {
  addresses,
  chain,
  explorerAddress,
  publicClient,
  READ_DEADLINE_MS,
  type ContractName,
} from "./config";
import { read, type Policy, type Snapshot } from "./chain";
import {
  amount,
  automaticStart,
  DURATIONS,
  explainError,
  fullAmount,
  integer,
  minimumOutput,
  requiredZeros,
  THRESHOLDS,
  validateStart,
  withDeadline,
} from "./domain";
import { PolicyBookAbi } from "./abis";
import { Icon } from "./Icons";
import { TransactionStatus, type Transactions } from "./transactions";

type Shared = {
  snapshot?: Snapshot;
  verified: boolean;
  onConnect: () => void;
  tx: Transactions;
  now: number;
};
export function ActionPanel(
  props: Shared & {
    tab: number;
    setTab: (tab: number) => void;
    policyInput: string;
    setPolicyInput: (id: string) => void;
  },
) {
  const tabs = ["Get COVER", "Liquidity", "Settle"];
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);
  return (
    <section className="action-panel" id="workspace" aria-label="COVER actions">
      <div className="tabs" role="tablist" aria-label="Choose an action">
        {tabs.map((label, i) => (
          <button
            role="tab"
            key={label}
            id={`tab-${i}`}
            aria-controls={`panel-${i}`}
            aria-selected={props.tab === i}
            tabIndex={props.tab === i ? 0 : -1}
            ref={(element) => {
              tabRefs.current[i] = element;
            }}
            onClick={() => props.setTab(i)}
            onKeyDown={(e) => {
              const next =
                e.key === "ArrowRight"
                  ? (i + 1) % 3
                  : e.key === "ArrowLeft"
                    ? (i + 2) % 3
                    : e.key === "Home"
                      ? 0
                      : e.key === "End"
                        ? 2
                        : undefined;
              if (next !== undefined) {
                e.preventDefault();
                props.setTab(next);
                tabRefs.current[next]?.focus();
              }
            }}
          >
            {label}
          </button>
        ))}
      </div>
      <div
        className="panel-content"
        role="tabpanel"
        id={`panel-${props.tab}`}
        aria-labelledby={`tab-${props.tab}`}
      >
        {props.tab === 0 ? (
          <CoverForm {...props} />
        ) : props.tab === 1 ? (
          <LiquidityForm {...props} />
        ) : (
          <SettleForm
            {...props}
            policyInput={props.policyInput}
            setPolicyInput={props.setPolicyInput}
          />
        )}
      </div>
      <TransactionStatus tx={props.tx} />
    </section>
  );
}
function FormError({ children, id }: { children: ReactNode; id: string }) {
  const ref = useRef<HTMLParagraphElement>(null);
  useEffect(() => {
    if (children) ref.current?.scrollIntoView({ block: "nearest" });
  }, [children]);
  return children ? (
    <p ref={ref} id={id} className="notice error" role="alert">
      {children}
    </p>
  ) : null;
}
// Errors that come from the user's input refocus the field; read failures do not.
const isInputError = (message: string) =>
  /^(Enter a positive|Choose a start|Start at most|The end round)/.test(
    message,
  );
function TokenChip({ id, prefix }: { id: string; prefix?: string }) {
  return (
    <span className="token-chip" id={id}>
      {prefix}mSQK (on-chain symbol SQI)
    </span>
  );
}
function WalletGate({
  verified,
  children,
  onConnect,
}: Pick<Shared, "verified" | "onConnect"> & { children: ReactNode }) {
  const { isConnected, chainId } = useConnection();
  if (!isConnected)
    return (
      <>
        <button className="button primary full" onClick={onConnect}>
          Connect to continue <Icon name="wallet" />
        </button>
        <p className="small muted">Connecting does not send a transaction.</p>
      </>
    );
  if (chainId !== chain.id)
    return (
      <p className="notice warning">
        Switch to Sepolia using the wallet control above. Transaction actions
        are unavailable on this chain.
      </p>
    );
  if (!verified)
    return (
      <p className="notice warning">
        Deployment checks have not passed. Refresh live data before sending a
        transaction.
      </p>
    );
  return children;
}
function Allowance({
  spender,
  value,
  tx,
  children,
}: {
  spender: "PolicyBook" | "CoverPool";
  value: bigint;
  tx: Transactions;
  children: ReactNode;
}) {
  const { address } = useConnection();
  const allowance = useQuery({
    queryKey: ["allowance", address, spender],
    enabled: !!address,
    queryFn: () =>
      withDeadline(
        read<bigint>("MockSQK", "allowance", [address!, addresses[spender]]),
        READ_DEADLINE_MS,
        "Checking mSQK approval",
      ),
    retry: false,
    refetchInterval: 15_000,
  });
  if (allowance.isPending)
    return (
      <p className="small" role="status">
        Checking mSQK approval…
      </p>
    );
  if (allowance.isError)
    return (
      <>
        <p className="notice error">{explainError(allowance.error)}</p>
        <button className="button" onClick={() => allowance.refetch()}>
          Retry approval check
        </button>
      </>
    );
  return allowance.data < value ? (
    <>
      <p className="small muted">
        First approve exactly {fullAmount(value)} mSQK for{" "}
        <a
          href={explorerAddress(addresses[spender])}
          target="_blank"
          rel="noreferrer"
        >
          {spender}
        </a>
        . This is a separate transaction.
      </p>
      <button
        className="button primary full"
        disabled={tx.busy}
        onClick={() =>
          tx.run("Approval", async (send) => {
            await send(
              "MockSQK",
              "approve",
              [addresses[spender], value],
              "Approve mSQK",
            );
          })
        }
      >
        Approve mSQK <Icon name="arrow" />
      </button>
    </>
  ) : (
    children
  );
}

type Quote = {
  start: bigint;
  end: bigint;
  rounds: number;
  threshold: number;
  cover: bigint;
  premium: bigint;
  deadline: bigint;
  inputKey: string;
};
function CoverForm({ snapshot, verified, onConnect, tx, now }: Shared) {
  const [cover, setCover] = useState("100");
  const [rounds, setRounds] = useState<number>(6);
  const [threshold, setThreshold] = useState<number>(5000);
  const [start, setStart] = useState("");
  const [quote, setQuote] = useState<Quote>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [acknowledged, setAcknowledged] = useState(false);
  const amountRef = useRef<HTMLInputElement>(null);
  const submitRef = useRef<HTMLButtonElement>(null);
  const key = `${cover}/${rounds}/${threshold}/${start}`;
  const currentKey = useRef(key);
  currentKey.current = key;
  const validQuote = quote?.inputKey === key ? quote : undefined;
  const failed = !!error && !loading && !isInputError(error);
  const expired =
    validQuote && BigInt(Math.floor(now / 1000)) > validQuote.deadline;
  const lagging =
    snapshot?.frontier !== undefined &&
    snapshot.current !== undefined &&
    snapshot.current - snapshot.frontier > 3n;
  useEffect(() => {
    setAcknowledged(false);
    setError("");
  }, [key]);
  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setError("");
    setQuote(undefined);
    setLoading(true);
    const capturedKey = key;
    try {
      const coverValue = amount(cover);
      const startInput = start.trim()
        ? integer(start, "Start round", (1n << 64n) - 1n)
        : undefined;
      const { startValue, premium, end, block } = await withDeadline(
        (async () => {
          const [frontier, current] = await read<
            readonly [bigint, bigint, boolean]
          >("CoreReader", "snapshot");
          const startValue = startInput ?? automaticStart(frontier, current);
          validateStart(startValue, frontier, current, rounds);
          const [[premium, end], block] = await Promise.all([
            read<readonly [bigint, bigint]>("PolicyBook", "quote", [
              startValue,
              rounds,
              threshold,
              coverValue,
            ]),
            publicClient.getBlock(),
          ]);
          return { startValue, premium, end, block };
        })(),
        READ_DEADLINE_MS,
        "Reading the quote",
      );
      if (currentKey.current === capturedKey)
        setQuote({
          start: startValue,
          end,
          premium,
          cover: coverValue,
          rounds,
          threshold,
          deadline: block.timestamp + 300n,
          inputKey: capturedKey,
        });
    } catch (e) {
      if (currentKey.current === capturedKey) {
        const message = explainError(e);
        setError(message);
        if (isInputError(message)) amountRef.current?.focus();
        else requestAnimationFrame(() => submitRef.current?.focus());
      }
    } finally {
      setLoading(false);
    }
  }
  return (
    <>
      <div className="panel-heading">
        <h2>Choose your cover</h2>
        <span className="small muted">mSQK</span>
      </div>
      <form onSubmit={getQuote}>
        <div className="label-row">
          <label htmlFor="cover-amount">Cover amount</label>
          <TokenChip id="cover-token" />
        </div>
        <div className="amount-field">
          <input
            ref={amountRef}
            id="cover-amount"
            name="cover"
            inputMode="decimal"
            autoComplete="off"
            value={cover}
            onChange={(e) => setCover(e.target.value)}
            aria-invalid={
              error.startsWith("Enter a positive amount") || undefined
            }
            aria-describedby={
              error
                ? "cover-token cover-help cover-error"
                : "cover-token cover-help"
            }
          />
          <span>mSQK</span>
        </div>
        <fieldset>
          <legend>
            Window <span className="muted">· rounds</span>
          </legend>
          <div className="choices">
            {DURATIONS.map((n) => (
              <label key={n}>
                <input
                  type="radio"
                  name="rounds"
                  value={n}
                  checked={rounds === n}
                  onChange={() => setRounds(n)}
                />
                <span>{n}</span>
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset>
          <legend>Zero-work threshold</legend>
          <div className="choices">
            {THRESHOLDS.map((t) => (
              <label key={t}>
                <input
                  type="radio"
                  name="threshold"
                  value={t}
                  checked={threshold === t}
                  onChange={() => setThreshold(t)}
                />
                <span>{t / 100}%</span>
              </label>
            ))}
          </div>
        </fieldset>
        <p className="threshold-note" id="cover-help">
          <Icon name="layers" size={16} /> Pays at{" "}
          {requiredZeros(rounds, threshold)} or more zero-work rounds.
        </p>
        <button
          ref={submitRef}
          className={
            failed
              ? "button full failed"
              : validQuote && !expired
                ? "button full"
                : "button primary full"
          }
          disabled={loading || tx.busy}
          aria-describedby={error ? "cover-error" : undefined}
          type="submit"
        >
          {loading
            ? "Reading quote…"
            : failed
              ? "Retry quote"
              : validQuote
                ? "Refresh quote"
                : "Get quote"}
          <Icon name={failed ? "alert" : "arrow"} />
        </button>
        <FormError id="cover-error">{error}</FormError>
        <p className="small muted no-wallet">
          No wallet needed to quote. Testnet tokens only.
        </p>
        <details className="advanced">
          <summary>Choose a start round</summary>
          <label htmlFor="start-round">
            Start round <span className="muted">(optional)</span>
          </label>
          <input
            id="start-round"
            name="startRound"
            inputMode="numeric"
            autoComplete="off"
            placeholder="Automatic: latest round + 2"
            value={start}
            onChange={(e) => setStart(e.target.value)}
          />
          <p className="small muted">
            Must follow both frontier and current round, within 1,008 rounds of
            current. Leave blank to choose automatically.
          </p>
        </details>
      </form>
      {validQuote && (
        <div className="action-result" aria-label="COVER quote">
          <h3>Review your quote</h3>
          <dl className="review-list">
            <div>
              <dt>Premium / maximum</dt>
              <dd>{fullAmount(validQuote.premium)} mSQK</dd>
            </div>
            <div>
              <dt>Fixed payout if triggered</dt>
              <dd>{fullAmount(validQuote.cover)} mSQK</dd>
            </div>
            <div>
              <dt>Inclusive window</dt>
              <dd>
                {validQuote.start.toString()}–{validQuote.end.toString()}
              </dd>
            </div>
            <div>
              <dt>Quote deadline</dt>
              <dd>
                {new Date(
                  Number(validQuote.deadline) * 1000,
                ).toLocaleTimeString()}
              </dd>
            </div>
          </dl>
          <p className="small muted">
            Premium stays in the pool in either outcome. Gas is paid separately
            in Sepolia ETH. You are the beneficiary.
          </p>
          {expired ? (
            <p className="notice warning">
              Quote expired. Refresh it before proceeding.
            </p>
          ) : (
            <>
              {lagging && (
                <p className="notice warning">
                  Core is lagging. This cover may stay reserved indefinitely.
                </p>
              )}
              <label className="check-row">
                <input
                  type="checkbox"
                  checked={acknowledged}
                  onChange={(e) => setAcknowledged(e.target.checked)}
                />
                I understand the{" "}
                <a href="#risks">testnet and reservation risks</a>.
              </label>
              <WalletGate verified={verified} onConnect={onConnect}>
                {acknowledged ? (
                  <Allowance
                    spender="PolicyBook"
                    value={validQuote.premium}
                    tx={tx}
                  >
                    <button
                      className="button primary full"
                      disabled={tx.busy}
                      onClick={() =>
                        tx.run("Policy opening", async (send) => {
                          if (
                            BigInt(Math.floor(Date.now() / 1000)) >
                            validQuote.deadline
                          )
                            throw new Error(
                              "Quote expired. Refresh before opening.",
                            );
                          const receipt = await send(
                            "PolicyBook",
                            "openPolicy",
                            [
                              validQuote.start,
                              validQuote.rounds,
                              validQuote.threshold,
                              validQuote.cover,
                              validQuote.premium,
                              validQuote.deadline,
                            ],
                            "Open policy",
                          );
                          for (const log of receipt.logs) {
                            if (
                              log.address.toLowerCase() !== addresses.PolicyBook
                            )
                              continue;
                            try {
                              const event = decodeEventLog({
                                abi: PolicyBookAbi,
                                data: log.data,
                                topics: log.topics,
                                eventName: "PolicyOpened",
                              });
                              tx.setPolicyId(event.args.policyId);
                            } catch {
                              /* Other events in the receipt. */
                            }
                          }
                          setQuote(undefined);
                        })
                      }
                    >
                      Open policy <Icon name="arrow" />
                    </button>
                  </Allowance>
                ) : (
                  <p className="small muted">
                    Acknowledge the risks to enable approval and opening.
                  </p>
                )}
              </WalletGate>
            </>
          )}
        </div>
      )}
    </>
  );
}

type LiquidityPreview = {
  mode: "deposit" | "redeem";
  input: bigint;
  output: bigint;
  minimum: bigint;
  key: string;
  epoch: bigint;
};
function LiquidityForm({ snapshot, verified, onConnect, tx }: Shared) {
  const { address } = useConnection();
  const [mode, setMode] = useState<"deposit" | "redeem">("deposit");
  const [value, setValue] = useState("");
  const [preview, setPreview] = useState<LiquidityPreview>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [acknowledged, setAcknowledged] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const submitRef = useRef<HTMLButtonElement>(null);
  const key = `${mode}/${value}/${address}`;
  const currentKey = useRef(key);
  currentKey.current = key;
  const balances = useQuery({
    queryKey: ["balances", address],
    enabled: !!address,
    queryFn: async () => {
      const [tokens, shares] = await withDeadline(
        Promise.all([
          read<bigint>("MockSQK", "balanceOf", [address!]),
          read<bigint>("CoverPool", "sharesOf", [address!]),
        ]),
        READ_DEADLINE_MS,
        "Reading your balance",
      );
      return { tokens, shares };
    },
    retry: false,
    refetchInterval: 30_000,
  });
  useEffect(() => {
    setPreview(undefined);
    setError("");
    setAcknowledged(false);
  }, [key]);
  async function onPreview(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError("");
    setPreview(undefined);
    const captured = key;
    try {
      const input =
        mode === "deposit" ? amount(value) : integer(value, "Share units");
      const [output, epoch, pending, bound, free, owned] = await withDeadline(
        Promise.all([
          read<bigint>(
            "CoverPool",
            mode === "deposit" ? "previewDeposit" : "previewRedeem",
            [input],
          ),
          read<bigint>("CoverPool", "shareEpoch"),
          read<boolean>("PolicyBook", "settlementPending"),
          read<string>("CoverPool", "policyBook"),
          mode === "redeem"
            ? read<bigint>("CoverPool", "freeAssets")
            : Promise.resolve(undefined),
          mode === "redeem" && address
            ? read<bigint>("CoverPool", "sharesOf", [address])
            : Promise.resolve(undefined),
        ]),
        READ_DEADLINE_MS,
        "Reading the preview",
      );
      if (bound.toLowerCase() !== addresses.PolicyBook)
        throw new Error(
          "The pool is not activated. The owner must bind PolicyBook before deposits.",
        );
      if (pending)
        throw new Error(
          "Settlement or review is pending. Use the Settle panel before moving LP liquidity.",
        );
      if (mode === "redeem") {
        if (free !== undefined && output > free)
          throw new Error(
            "This redemption exceeds free liquidity. Reduce the share units or wait for settlement.",
          );
        if (owned !== undefined && input > owned)
          throw new Error(
            "This exceeds your current-epoch shares. Refresh your balance or reduce the amount.",
          );
      }
      if (currentKey.current === captured)
        setPreview({
          mode,
          input,
          output,
          minimum: minimumOutput(output),
          key: captured,
          epoch,
        });
    } catch (e) {
      if (currentKey.current === captured) {
        const message = explainError(e);
        setError(message);
        if (isInputError(message)) inputRef.current?.focus();
        else requestAnimationFrame(() => submitRef.current?.focus());
      }
    } finally {
      setLoading(false);
    }
  }
  const valid = preview?.key === key ? preview : undefined;
  const failed = !!error && !loading && !isInputError(error);
  const write = async () => {
    if (!valid) return;
    await tx.run(
      mode === "deposit" ? "Deposit" : "Redemption",
      async (send) => {
        if ((await read<bigint>("CoverPool", "shareEpoch")) !== valid.epoch)
          throw new Error(
            "The pool share epoch changed. Preview again before sending.",
          );
        await send(
          "CoverPool",
          valid.mode,
          [valid.input, valid.minimum],
          valid.mode === "deposit" ? "Deposit mSQK" : "Redeem shares",
        );
        setPreview(undefined);
      },
    );
  };
  const action = (
    <button className="button primary full" disabled={tx.busy} onClick={write}>
      {mode === "deposit" ? "Deposit mSQK" : "Redeem shares"}{" "}
      <Icon name="arrow" />
    </button>
  );
  return (
    <>
      <h2>Provide pool liquidity</h2>
      <p className="small muted">
        Earn a share of premiums; bear COVER payouts. Reserved collateral cannot
        be redeemed.
      </p>
      <fieldset>
        <legend className="sr-only">Liquidity action</legend>
        <div className="choices">
          {(["deposit", "redeem"] as const).map((v) => (
            <label key={v}>
              <input
                type="radio"
                name="liquidity-mode"
                checked={mode === v}
                onChange={() => setMode(v)}
              />
              <span>{v === "deposit" ? "Deposit" : "Redeem"}</span>
            </label>
          ))}
        </div>
      </fieldset>
      {address && (
        <div className="balance-line small">
          {balances.data ? (
            mode === "deposit" ? (
              <>
                Wallet: <span>{fullAmount(balances.data.tokens)} mSQK</span>
              </>
            ) : (
              <>
                Owned:{" "}
                <span>{balances.data.shares.toString()} share units</span>
                <button
                  className="text-button"
                  disabled={tx.busy}
                  onClick={() => setValue(balances.data!.shares.toString())}
                >
                  Use all
                </button>
              </>
            )
          ) : balances.isError ? (
            <button className="text-button" onClick={() => balances.refetch()}>
              Retry balance read
            </button>
          ) : (
            "Reading balance…"
          )}
        </div>
      )}
      <form onSubmit={onPreview}>
        <div className="label-row">
          <label htmlFor="lp-amount">
            {mode === "deposit"
              ? "Deposit amount in mSQK"
              : "Share units to redeem"}
          </label>
          <TokenChip
            id="lp-token"
            prefix={mode === "deposit" ? undefined : "Pays out "}
          />
        </div>
        <input
          ref={inputRef}
          id="lp-amount"
          name="liquidityAmount"
          inputMode={mode === "deposit" ? "decimal" : "numeric"}
          autoComplete="off"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          aria-invalid={error.startsWith("Enter a positive") || undefined}
          aria-describedby={
            error ? "lp-token lp-help lp-error" : "lp-token lp-help"
          }
          placeholder={mode === "deposit" ? "0.00" : "Whole share units"}
        />
        <p className="small muted" id="lp-help">
          {mode === "deposit"
            ? "mSQK uses 18 decimals. Only the owner can mint tokens."
            : "Pool shares are raw integer units, not mSQK amounts."}
        </p>
        <button
          ref={submitRef}
          className={
            failed
              ? "button full failed"
              : valid
                ? "button full"
                : "button primary full"
          }
          disabled={loading || tx.busy}
          aria-describedby={error ? "lp-error" : undefined}
          type="submit"
        >
          {loading
            ? "Reading preview…"
            : `${failed ? "Retry" : "Preview"} ${mode === "deposit" ? "deposit" : "redemption"}`}
          <Icon name={failed ? "alert" : "arrow"} />
        </button>
        <FormError id="lp-error">{error}</FormError>
      </form>
      {snapshot?.pending && (
        <p className="notice warning">
          The pool is waiting for policy settlement or review. Check the Settle
          panel.
        </p>
      )}
      {valid && (
        <div className="action-result">
          <h3>Review {mode === "deposit" ? "deposit" : "redemption"}</h3>
          <dl className="review-list">
            <div>
              <dt>You send</dt>
              <dd>
                {mode === "deposit"
                  ? `${fullAmount(valid.input)} mSQK`
                  : `${valid.input} share units`}
              </dd>
            </div>
            <div>
              <dt>Expected output</dt>
              <dd>
                {mode === "deposit"
                  ? `${valid.output} share units`
                  : `${fullAmount(valid.output)} mSQK`}
              </dd>
            </div>
            <div>
              <dt>Minimum output (0.5% tolerance)</dt>
              <dd>
                {mode === "deposit"
                  ? `${valid.minimum} share units`
                  : `${fullAmount(valid.minimum)} mSQK`}
              </dd>
            </div>
          </dl>
          <label className="check-row">
            <input
              type="checkbox"
              checked={acknowledged}
              onChange={(e) => setAcknowledged(e.target.checked)}
            />
            I understand pool losses and indefinite reservation risk.
          </label>
          <WalletGate verified={verified} onConnect={onConnect}>
            {acknowledged ? (
              mode === "deposit" ? (
                <Allowance spender="CoverPool" value={valid.input} tx={tx}>
                  {action}
                </Allowance>
              ) : (
                action
              )
            ) : (
              <p className="small muted">Acknowledge the risks to continue.</p>
            )}
          </WalletGate>
        </div>
      )}
    </>
  );
}

export const policyStatus = (status: number) =>
  ["Not found", "Open", "Paid", "Expired"][status] ?? "Unknown";
function SettleForm({
  snapshot,
  verified,
  onConnect,
  tx,
  policyInput,
  setPolicyInput,
}: Shared & { policyInput: string; setPolicyInput: (id: string) => void }) {
  const [result, setResult] = useState<{
    id: bigint;
    policy: Policy;
    zeros?: number;
    certified?: number;
    warning?: string;
  }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const submitRef = useRef<HTMLButtonElement>(null);
  const currentKey = useRef(policyInput);
  currentKey.current = policyInput;
  const gate = useQuery({
    queryKey: ["gateIds", snapshot?.block.toString()],
    enabled: !!snapshot?.pending && snapshot.decide !== undefined,
    queryFn: () =>
      withDeadline(
        read<readonly bigint[]>("PolicyBook", "openPolicyIdsDecidingAt", [
          snapshot!.decide!,
        ]),
        READ_DEADLINE_MS,
        "Reading pending policy IDs",
      ),
    retry: false,
  });
  const visible =
    result?.id.toString() === policyInput.trim() ? result : undefined;
  async function lookup(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError("");
    setResult(undefined);
    const captured = policyInput;
    try {
      const id = integer(policyInput);
      const next = await withDeadline(
        (async () => {
          const policy = await read<Policy>("PolicyBook", "getPolicy", [id]);
          if (!policy.status)
            throw new Error(
              "No policy exists with this ID. Check the ID or choose a policy from the live list.",
            );
          const next: NonNullable<typeof result> = { id, policy };
          if (policy.status === 1) {
            try {
              [next.zeros, next.certified] = await read<
                readonly [number, number]
              >("CoreReader", "certifiedZeroRounds", [
                policy.startRound,
                policy.rounds,
              ]);
            } catch (e) {
              next.warning = explainError(e);
            }
          }
          return next;
        })(),
        READ_DEADLINE_MS,
        "Reading the policy",
      );
      if (currentKey.current === captured) setResult(next);
    } catch (e) {
      if (currentKey.current === captured) {
        const message = explainError(e);
        setError(message);
        if (/^(Enter a positive|No policy exists)/.test(message))
          inputRef.current?.focus();
        else requestAnimationFrame(() => submitRef.current?.focus());
      }
    } finally {
      setLoading(false);
    }
  }
  const settled = visible && visible.policy.status !== 1;
  const failed =
    !!error && !loading && !/^(Enter a positive|No policy exists)/.test(error);
  const canSettle =
    visible &&
    visible.zeros !== undefined &&
    visible.certified !== undefined &&
    (visible.zeros >=
      requiredZeros(visible.policy.rounds, visible.policy.thresholdBps) ||
      visible.zeros + visible.policy.rounds - visible.certified <
        requiredZeros(visible.policy.rounds, visible.policy.thresholdBps));
  const settle = (method: "settle" | "review") => {
    if (!visible) return;
    tx.run(
      method === "settle" ? "Settlement" : "Policy review",
      async (send) => {
        await send(
          "PolicyBook",
          method,
          [visible.id],
          method === "settle" ? "Settle policy" : "Review policy",
        );
        setResult(undefined);
      },
    );
  };
  return (
    <>
      <h2>Settle a policy</h2>
      <p className="small muted">
        Anyone can settle. The payout always goes to the policy holder; callers
        receive no reward.
      </p>
      <form onSubmit={lookup}>
        <label htmlFor="policy-id">Policy ID</label>
        <input
          ref={inputRef}
          id="policy-id"
          name="policyId"
          aria-invalid={error.startsWith("Enter a positive") || undefined}
          aria-describedby={error ? "policy-error" : undefined}
          inputMode="numeric"
          autoComplete="off"
          value={policyInput}
          onChange={(e) => {
            setPolicyInput(e.target.value);
            setError("");
          }}
          placeholder="Enter an on-chain policy ID"
        />
        <button
          ref={submitRef}
          type="submit"
          className={
            failed
              ? "button full failed"
              : visible
                ? "button full"
                : "button primary full"
          }
          disabled={loading || tx.busy}
          aria-describedby={error ? "policy-error" : undefined}
        >
          {loading
            ? "Reading policy…"
            : failed
              ? "Retry lookup"
              : "Look up policy"}
          <Icon name={failed ? "alert" : "arrow"} />
        </button>
        <FormError id="policy-error">{error}</FormError>
      </form>
      {snapshot?.pending && (
        <div className="small notice warning">
          LP movements are gated.{" "}
          {gate.data ? (
            <>
              Review or settle:{" "}
              {gate.data.map((id) => (
                <button
                  key={id.toString()}
                  className="text-button"
                  onClick={() => setPolicyInput(id.toString())}
                >
                  #{id.toString()}
                </button>
              ))}
            </>
          ) : gate.isError ? (
            <button className="text-button" onClick={() => gate.refetch()}>
              Retry pending policy IDs
            </button>
          ) : (
            "Reading pending policy IDs…"
          )}
        </div>
      )}
      {visible && (
        <div className="action-result">
          <div className="panel-heading">
            <h3>Policy #{visible.id.toString()}</h3>
            <span className="status-tag">
              {policyStatus(visible.policy.status)}
            </span>
          </div>
          <dl className="review-list">
            <div>
              <dt>Fixed cover</dt>
              <dd>{fullAmount(visible.policy.cover)} mSQK</dd>
            </div>
            <div>
              <dt>Premium paid</dt>
              <dd>{fullAmount(visible.policy.premium)} mSQK</dd>
            </div>
            <div>
              <dt>Window</dt>
              <dd>
                {visible.policy.startRound.toString()}–
                {visible.policy.endRound.toString()}
              </dd>
            </div>
            <div>
              <dt>Zero-work threshold</dt>
              <dd>
                {visible.policy.thresholdBps / 100}% of {visible.policy.rounds}
              </dd>
            </div>
            {visible.zeros !== undefined && (
              <div>
                <dt>Certified zero-work rounds</dt>
                <dd>
                  {visible.zeros} of {visible.certified} certified
                </dd>
              </div>
            )}
            <div>
              <dt>Holder</dt>
              <dd>
                <a
                  className="address"
                  href={explorerAddress(visible.policy.holder)}
                  target="_blank"
                  rel="noreferrer"
                >
                  {visible.policy.holder}
                </a>
              </dd>
            </div>
          </dl>
          {visible.warning && (
            <p className="notice warning">{visible.warning}</p>
          )}
          {settled ? (
            <p className="small">
              {visible.policy.status === 2
                ? `Paid ${fullAmount(visible.policy.cover)} mSQK to the holder.`
                : "No payout. The premium stayed in the pool."}
            </p>
          ) : (
            <>
              <p className="small muted">
                {canSettle
                  ? "Certified history fixes the outcome. Settlement is available."
                  : "Outcome is not yet fixed by readable certified history. Review can update the LP gate; it cannot force a refund."}
              </p>
              <WalletGate verified={verified} onConnect={onConnect}>
                <button
                  className="button primary full"
                  disabled={tx.busy || !canSettle}
                  onClick={() => settle("settle")}
                >
                  Settle policy <Icon name="arrow" />
                </button>
                <button
                  className="button full"
                  disabled={tx.busy || visible.certified === undefined}
                  onClick={() => settle("review")}
                >
                  Review policy
                </button>
              </WalletGate>
            </>
          )}
        </div>
      )}
    </>
  );
}
