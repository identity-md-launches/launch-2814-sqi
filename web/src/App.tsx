import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ActionPanel, policyStatus } from "./Actions";
import {
  fetchPolicies,
  fetchSnapshot,
  verifyDeployment,
  type Snapshot,
} from "./chain";
import { addresses, explorerAddress, EXPLORER, JOB, REPO } from "./config";
import { explainError, fullAmount } from "./domain";
import { Icon, Mark } from "./Icons";
import { useTransactions } from "./transactions";
import { WalletControl } from "./Wallet";

function Metric({
  label,
  value,
  unit,
  hint,
}: {
  label: string;
  value?: bigint;
  unit?: string;
  hint: string;
}) {
  return (
    <div className="metric">
      <dt>{label}</dt>
      <dd>
        {value === undefined ? (
          <span className="unavailable">Unavailable</span>
        ) : unit === "mSQK" ? (
          fullAmount(value)
        ) : (
          value.toLocaleString()
        )}
        {value !== undefined && unit && (
          <span className="metric-unit">{unit}</span>
        )}
        <p className="small muted">{hint}</p>
      </dd>
    </div>
  );
}
function LiveDashboard({
  snapshot,
  loading,
  paused,
  failed,
  error,
  onRefresh,
  refreshing,
  now,
  inspect,
}: {
  snapshot?: Snapshot;
  loading: boolean;
  paused: boolean;
  failed: boolean;
  error: unknown;
  onRefresh: () => void;
  refreshing: boolean;
  now: number;
  inspect: (id: string) => void;
}) {
  const lag =
    snapshot?.current !== undefined && snapshot.frontier !== undefined
      ? snapshot.current - snapshot.frontier
      : undefined;
  const stale =
    snapshot &&
    (now - snapshot.fetchedAt > 90_000 ||
      now / 1000 - Number(snapshot.timestamp) > 180);
  const unavailable = failed || paused;
  return (
    <section
      id="live"
      className="section live-section"
      aria-labelledby="live-title"
    >
      <div className="section-heading">
        <div>
          <h2 id="live-title">On-chain, in plain sight.</h2>
          <p className="muted">
            Sepolia state, read directly from the contracts.
          </p>
        </div>
        <button
          className={
            unavailable && !refreshing ? "button subtle failed" : "button subtle"
          }
          onClick={onRefresh}
          disabled={refreshing}
          aria-describedby={unavailable ? "live-error" : undefined}
        >
          <Icon name={unavailable && !refreshing ? "alert" : "refresh"} />
          {refreshing ? "Refreshing…" : unavailable ? "Retry" : "Refresh"}
        </button>
      </div>
      <div className="data-status small">
        <span
          className={`status-dot ${loading || unavailable || stale ? "warn" : ""}`}
          aria-hidden="true"
        />
        {paused ? (
          "Offline"
        ) : loading ? (
          "Reading Sepolia…"
        ) : !snapshot ? (
          "Live data unavailable"
        ) : (
          <>
            <span>
              {unavailable || stale ? "Last successful read" : "Read at"}{" "}
              {new Date(snapshot.fetchedAt).toLocaleTimeString()}
            </span>
            <a
              href={`${EXPLORER}/block/${snapshot.block}`}
              target="_blank"
              rel="noreferrer"
            >
              Block {snapshot.block.toLocaleString()}{" "}
              <Icon name="external" size={14} />
            </a>
          </>
        )}
        <span className="refresh-note">
          {paused ? "Live reads paused" : "Refreshes every 30 seconds"}
        </span>
      </div>
      {unavailable && (
        <p role="status" className="notice error" id="live-error">
          {paused
            ? "You are offline. Reconnect, then retry."
            : explainError(error)}{" "}
          {snapshot
            ? "Values below are from the last successful read."
            : "No balances or rounds are estimated."}
        </p>
      )}
      {stale && !unavailable && (
        <p className="notice warning">
          The snapshot is stale. Refresh before relying on these values.
        </p>
      )}
      {lag !== undefined && lag > 3n && (
        <div className="notice warning lag-notice">
          <Icon name="alert" />
          <div>
            <strong>Core is lagging by {lag.toLocaleString()} rounds.</strong>
            <p>
              Certification trails the clock. Settlement may be delayed
              indefinitely; future rounds are unknown.
            </p>
          </div>
        </div>
      )}
      <dl className="metrics-grid">
        <Metric
          label="Certified frontier"
          value={snapshot?.frontier}
          hint="Last round certified by Core"
        />
        <Metric
          label="Current round"
          value={snapshot?.current}
          hint="Derived from the Core clock"
        />
        <Metric
          label="Open policies"
          value={snapshot?.open}
          hint="Unresolved COVER policies"
        />
        <Metric
          label="Pool assets"
          value={snapshot?.assets}
          unit="mSQK"
          hint="Accounted collateral, not a fiat value"
        />
        <Metric
          label="Reserved cover"
          value={snapshot?.reserved}
          unit="mSQK"
          hint="Committed to open policies"
        />
        <Metric
          label="Free liquidity"
          value={snapshot?.free}
          unit="mSQK"
          hint="Assets less reserved cover"
        />
      </dl>
      <div className="pool-state small">
        <span>
          Pool binding:{" "}
          <strong>
            {snapshot?.configured === undefined
              ? "unknown"
              : snapshot.configured
                ? "configured"
                : "awaiting owner activation"}
          </strong>
        </span>
        <span>
          New policies:{" "}
          <strong>
            {snapshot?.paused === undefined || snapshot.corePaused === undefined
              ? "unknown"
              : snapshot.paused || snapshot.corePaused
                ? "paused"
                : "not paused"}
          </strong>
        </span>
        <span>
          LP gate:{" "}
          <strong>
            {snapshot?.pending === undefined
              ? "unknown"
              : snapshot.pending
                ? "settlement / review needed"
                : "clear"}
          </strong>
        </span>
      </div>
      {snapshot &&
      (snapshot.configured === false || snapshot.assets === 0n) ? (
        <p className="small activation-note">
          <Icon name="alert" size={16} />
          <span>
            Demo pool not activated / unfunded. Quotes may fail until the owner
            binds PolicyBook, sets rates, and deposits liquidity (see{" "}
            <a
              href={`${REPO}/blob/main/LAUNCH.md`}
              target="_blank"
              rel="noreferrer"
            >
              LAUNCH.md
            </a>
            ).
          </span>
        </p>
      ) : null}
      {snapshot?.errors.length ? (
        <details className="read-errors">
          <summary>Some reads failed ({snapshot.errors.length})</summary>
          <ul>
            {snapshot.errors.map((message) => (
              <li key={message}>{message}</li>
            ))}
          </ul>
        </details>
      ) : null}
      <PolicyList snapshot={snapshot} inspect={inspect} />
    </section>
  );
}
function PolicyList({
  snapshot,
  inspect,
}: {
  snapshot?: Snapshot;
  inspect: (id: string) => void;
}) {
  const [page, setPage] = useState(0);
  const before =
    snapshot?.nextId !== undefined
      ? snapshot.nextId - BigInt(page * 5)
      : undefined;
  const policies = useQuery({
    queryKey: ["policies", before?.toString(), snapshot?.block.toString()],
    enabled: before !== undefined && before > 1n,
    queryFn: () => fetchPolicies(before!),
    placeholderData: (previous) => previous,
    retry: false,
  });
  return (
    <div className="policies">
      <div className="section-heading compact">
        <h3>Policy activity</h3>
        <span className="small muted">
          {policies.isPlaceholderData
            ? "Updating policy activity…"
            : page === 0
              ? "Latest policies · all statuses"
              : `Older policies · page ${page + 1}`}
        </span>
      </div>
      {snapshot?.nextId === undefined ? (
        <p className="empty-state">
          Policy activity is unavailable. Refresh the chain read or look up an
          ID in the Settle panel.
        </p>
      ) : snapshot.nextId <= 1n ? (
        <div className="empty-state">
          <Icon name="layers" />
          <div>
            <strong>No policies have been opened.</strong>
            <p className="small muted">
              Explore a quote above. Opening requires an activated, funded pool.
            </p>
          </div>
        </div>
      ) : policies.isError ? (
        <div className="notice error">
          <p>{explainError(policies.error)}</p>
          <button className="text-button" onClick={() => policies.refetch()}>
            Retry policy list
          </button>
        </div>
      ) : policies.isPending ? (
        <p className="empty-state" role="status">
          Reading policies…
        </p>
      ) : (
        <ul className="policy-list">
          {policies.data.map(({ id, policy }) => (
            <li key={id.toString()}>
              <div>
                <button
                  className="text-button"
                  onClick={() => inspect(id.toString())}
                >
                  Policy #{id.toString()} <Icon name="arrow" size={16} />
                </button>
                <span className="small muted">
                  Rounds {policy.startRound.toString()}–
                  {policy.endRound.toString()}
                </span>
              </div>
              <div className="policy-value">
                <strong>{fullAmount(policy.cover)} mSQK</strong>
                <span className="small muted">
                  {policy.thresholdBps / 100}% threshold
                </span>
              </div>
              <span className="status-tag">{policyStatus(policy.status)}</span>
            </li>
          ))}
        </ul>
      )}
      {snapshot?.nextId !== undefined && snapshot.nextId > 6n && (
        <div className="pager">
          <button
            className="button"
            disabled={page === 0}
            onClick={() => setPage((p) => Math.max(0, p - 1))}
          >
            Newer policies
          </button>
          <button
            className="button"
            disabled={before === undefined || before <= 6n}
            onClick={() => setPage((p) => p + 1)}
          >
            Older policies
          </button>
        </div>
      )}
    </div>
  );
}
function RoundDiagram() {
  return (
    <figure className="round-diagram">
      <div className="round-strip" aria-hidden="true">
        {[true, false, false, true, false, true].map((zero, i) => (
          <div className={zero ? "round zero" : "round"} key={i}>
            {zero ? (
              <span className="round-zero" />
            ) : (
              <svg viewBox="0 0 40 35">
                <path
                  d="M5 23h7l4-12 7 20 4-12h8"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                />
              </svg>
            )}
          </div>
        ))}
      </div>
      <figcaption>
        <span className="legend">
          <span className="legend-dot" />
          Zero-work
        </span>
        <span>3 of 6 rounds · 50% threshold</span>
      </figcaption>
      <p className="small muted">
        Illustrative window, not live round history.
      </p>
    </figure>
  );
}
type DiagramRound = "work" | "zero" | "missing" | "unknown";
const FRONTIER_EXAMPLE: DiagramRound[] = [
  "work",
  "zero",
  "missing",
  "work",
  "zero",
  "unknown",
  "unknown",
  "unknown",
];
const roundGlyph: Record<DiagramRound, string> = {
  work: "W",
  zero: "0",
  missing: "∅",
  unknown: "?",
};
function FrontierDiagram() {
  return (
    <figure className="frontier-diagram">
      <div className="frontier-strip" aria-hidden="true">
        {FRONTIER_EXAMPLE.map((kind, i) => (
          <div
            key={i}
            className={`frontier-round ${kind}${i === 4 ? " at-frontier" : ""}`}
          >
            <span className="frontier-index">{i + 1}</span>
            <span className="frontier-glyph">{roundGlyph[kind]}</span>
          </div>
        ))}
      </div>
      <div className="frontier-scale" aria-hidden="true">
        <span>Certified history</span>
        <span>Past the frontier</span>
      </div>
      <figcaption>
        <ul className="frontier-legend small">
          <li>
            <span className="key work">W</span> Work recorded
          </li>
          <li>
            <span className="key zero">0</span> Zero-work
          </li>
          <li>
            <span className="key missing">∅</span> Missing active record,
            counts as zero-work
          </li>
          <li>
            <span className="key unknown">?</span> Unknown, never counted as
            zero-work
          </li>
        </ul>
        <p className="small muted">
          Example only: rounds 1 to 5 are certified and 3 of them count as
          zero-work. Rounds 6 to 8 are past the frontier, so they count for
          nothing yet.
        </p>
      </figcaption>
    </figure>
  );
}
function Contracts({ verified, error }: { verified: boolean; error: unknown }) {
  const [copied, setCopied] = useState("");
  const purposes = {
    PolicyBook: "Quotes, policies & settlement",
    CoverPool: "Collateral & LP shares",
    PremiumModel: "Rates & utilization surcharge",
    CoreReader: "Certified-history adapter",
    MockSQK: "mSQK collateral · symbol SQI",
    SqueekCore: "Read-only upstream Core",
  };
  return (
    <section
      id="contracts"
      className="section"
      aria-labelledby="contracts-title"
    >
      <div className="section-heading">
        <div>
          <h2 id="contracts-title">Verify every address.</h2>
          <p className="muted">Sepolia deployment · chain ID 11155111.</p>
        </div>
        <span className="small verification">
          <Icon name={verified ? "check" : "alert"} size={16} />
          {verified
            ? "App code & dependency checks passed"
            : "Deployment checks pending or unavailable"}
        </span>
      </div>
      {error ? <p className="notice warning">{explainError(error)}</p> : null}
      <div className="contract-list">
        {Object.entries(addresses).map(([name, address]) => (
          <div className="contract-row" key={name}>
            <div>
              <h3>{name === "MockSQK" ? "MockSQK (mSQK)" : name}</h3>
              <p className="small muted">
                {purposes[name as keyof typeof purposes]}
              </p>
            </div>
            <a
              className="address"
              href={explorerAddress(address)}
              target="_blank"
              rel="noreferrer"
            >
              {address}
              <Icon name="external" size={16} />
            </a>
            <button
              className="icon-button"
              aria-label={`Copy ${name} address`}
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(address);
                  setCopied(`${name} address copied.`);
                } catch {
                  setCopied(
                    "Copy unavailable. Select the full address to copy it.",
                  );
                }
              }}
            >
              <Icon name="copy" size={18} />
            </button>
          </div>
        ))}
      </div>
      <p className="small copy-status" role="status">
        {copied}
      </p>
      <p className="small muted">
        App runtime is compared with the repository build; immutable dependency
        addresses are checked separately. This does not attest to the security
        of Core’s implementation.
      </p>
    </section>
  );
}
export default function App() {
  const [walletOpen, setWalletOpen] = useState(false);
  const [tab, setTab] = useState(0);
  const [policyInput, setPolicyInput] = useState("");
  const [now, setNow] = useState(Date.now());
  const queryClient = useQueryClient();
  const snapshot = useQuery({
    queryKey: ["snapshot"],
    queryFn: fetchSnapshot,
    retry: false,
    refetchInterval: 30_000,
    refetchIntervalInBackground: false,
  });
  const verification = useQuery({
    queryKey: ["deployment"],
    queryFn: verifyDeployment,
    retry: false,
    staleTime: 300_000,
  });
  const tx = useTransactions();
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  function inspect(id: string) {
    setPolicyInput(id);
    setTab(2);
    location.hash = "workspace";
    requestAnimationFrame(() => document.getElementById("policy-id")?.focus());
  }
  return (
    <>
      <a className="skip-link" href="#workspace">
        Skip to COVER actions
      </a>
      <div className="testnet-banner">
        <span className="status-dot" aria-hidden="true" />
        <span>Sepolia testnet</span>
        <span className="banner-divider" aria-hidden="true">
          /
        </span>
        <span>Mock tokens for real contract behavior.</span>
      </div>
      <header className="site-header shell">
        <a href="#top" className="brand" aria-label="SqueekFi COVER home">
          <Mark />
          <span>
            SqueekFi <strong>COVER</strong>
          </span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#live">Live state</a>
          <a href="#how">How it works</a>
          <a href="#risks">Risks</a>
        </nav>
        <WalletControl
          open={walletOpen}
          onOpen={() => setWalletOpen(true)}
          onClose={() => setWalletOpen(false)}
        />
      </header>
      <main className="shell" id="top">
        <div className="hero">
          <div className="hero-intro">
            <h1>
              COVER for
              <br />
              <span>zero-work rounds.</span>
            </h1>
            <p className="hero-description">
              Fixed-payout cover for SqueekCore rounds, paid in mock tokens on
              Sepolia.
            </p>
            <div className="hero-facts">
              <span>Certified history</span>
              <span>Permissionless settlement</span>
            </div>
            <RoundDiagram />
            <a className="hero-link" href="#how">
              Understand the payout <Icon name="arrow" size={18} />
            </a>
          </div>
          <ActionPanel
            snapshot={snapshot.data}
            verified={verification.isSuccess && !verification.isError}
            onConnect={() => setWalletOpen(true)}
            tx={tx}
            now={now}
            tab={tab}
            setTab={setTab}
            policyInput={policyInput}
            setPolicyInput={setPolicyInput}
          />
        </div>
        <div className="token-note small">
          <Icon name="alert" size={16} />
          <p>
            Demo collateral is called mSQK here. Its on-chain name and symbol
            are <strong>SQI</strong> (18 decimals). Only the owner can mint it.
            Read the <a href="#risks">risks</a> before using COVER.
          </p>
        </div>
        <LiveDashboard
          snapshot={snapshot.data}
          loading={snapshot.isPending}
          paused={snapshot.isPaused}
          failed={snapshot.isError}
          error={snapshot.error}
          onRefresh={() => {
            queryClient.invalidateQueries({ queryKey: ["snapshot"] });
            queryClient.invalidateQueries({ queryKey: ["deployment"] });
          }}
          refreshing={snapshot.isFetching}
          now={now}
          inspect={inspect}
        />
        <section id="how" className="section" aria-labelledby="how-title">
          <div className="section-heading">
            <div>
              <h2 id="how-title">How COVER pays out.</h2>
              <p className="muted">
                COVER follows certified rounds, not a wall-clock promise.
              </p>
            </div>
          </div>
          <p className="how-thesis">
            A buyer pays an mSQK premium for a fixed payout C. The claim pays if,
            over the next N certified SqueekCore rounds, the share of zero-work
            rounds is at least T.
          </p>
          <div className="rule-line">
            <strong>zero-work rounds / N ≥ T → payout C</strong>
            <p className="small muted">
              Premium stays in the pool in both outcomes. Only certified rounds
              are counted; time passing alone never creates a zero-work round.
            </p>
          </div>
          <ol className="steps how-steps">
            <li>
              <span className="step-number">01</span>
              <h3>Where rounds come from</h3>
              <div className="step-body">
                <p>
                  SqueekCore advances on a clock of about 10 minutes per round,
                  then certifies history up to its frontier.
                </p>
                <ul>
                  <li>Only rounds at or before the certified frontier count.</li>
                  <li>
                    A missing active record inside certified history counts as
                    zero-work.
                  </li>
                  <li>
                    Rounds past the frontier are unknown. They do not count as
                    zero-work just because time passed.
                  </li>
                  <li>If Core lags, settlement can wait indefinitely.</li>
                </ul>
                <FrontierDiagram />
              </div>
            </li>
            <li>
              <span className="step-number">02</span>
              <h3>Choose the terms</h3>
              <div className="step-body">
                <dl className="terms-list">
                  <div>
                    <dt>Window N</dt>
                    <dd>6, 12, 24 or 144 rounds</dd>
                  </div>
                  <div>
                    <dt>Threshold T</dt>
                    <dd>30%, 50% or 70% zero-work</dd>
                  </div>
                  <div>
                    <dt>Cover C</dt>
                    <dd>Fixed payout in mSQK</dd>
                  </div>
                </dl>
                <p>
                  You approve mSQK and open the policy. The premium goes to
                  CoverPool, and the pool reserves C until the policy settles.
                  Pricing uses owner-set rates plus a utilization surcharge.
                </p>
              </div>
            </li>
            <li>
              <span className="step-number">03</span>
              <h3>Settle the outcome</h3>
              <div className="step-body">
                <p>
                  Once the frontier reaches the inclusive end round, anyone may
                  settle. The caller earns nothing; any payout goes to the
                  holder.
                </p>
                <ul>
                  <li>If zero-work rounds / N ≥ T, the holder receives C.</li>
                  <li>Otherwise there is no payout.</li>
                  <li>The premium stays in the pool either way.</li>
                  <li>
                    Early settlement is allowed when a certified prefix already
                    decides the outcome: enough zero-work rounds to hit T, or
                    too few rounds left to reach it.
                  </li>
                </ul>
              </div>
            </li>
            <li>
              <span className="step-number">04</span>
              <h3>Liquidity providers</h3>
              <div className="step-body">
                <p>
                  LPs fund the pool that pays C. A deposit mints shares; a
                  redemption burns shares for free assets, never reserved ones.
                </p>
                <ul>
                  <li>
                    Gates can block LP deposits and redemptions while a
                    certified policy needs settlement or review.
                  </li>
                  <li>Shares can lose all value through payouts.</li>
                  <li>Reservations have no automatic timeout.</li>
                </ul>
              </div>
            </li>
          </ol>
          <details className="technical-note">
            <summary>Early settlement and LP gate details</summary>
            <p>
              Settlement reads the certified prefix of the window. When its
              zero-work count already reaches the required number, or the
              remaining rounds can no longer lift it to T, the outcome is fixed
              and settlement succeeds before the end round. Otherwise the
              contract rejects it as undecided.
            </p>
            <p>
              Review recomputes a policy&rsquo;s earliest decision round, which
              can reopen the LP gate; it cannot force a refund. Premiums add
              pool assets and payouts remove them, so share value moves with
              outcomes. LP previews here apply a 0.5% minimum-output tolerance
              and recheck the share epoch before sending.
            </p>
          </details>
        </section>
        <Contracts
          verified={verification.isSuccess}
          error={verification.error}
        />
        <section
          id="risks"
          className="section risks"
          aria-labelledby="risks-title"
        >
          <div className="section-heading">
            <div>
              <h2 id="risks-title">Understand the testnet risks.</h2>
              <p className="muted">
                Swarm review found medium-severity issues. This is not
                production-safe.
              </p>
            </div>
            <Icon name="alert" size={28} />
          </div>
          <div className="risk-grid">
            <article>
              <h3>Reservation locks</h3>
              <p>
                The audit flagged an unbounded startRound lock. This source caps
                the lead at 1,008 rounds, but a stalled frontier can still
                reserve collateral indefinitely. No timeout or forced refund
                exists.
              </p>
            </article>
            <article>
              <h3>LP exit before settlement</h3>
              <p>
                The audit flagged exits before losses settle. This source gates
                LP deposits and redemptions while a certified policy needs
                settlement or review. Gate maintenance costs gas; LP losses
                remain possible.
              </p>
            </article>
            <article>
              <h3>Strict CoreReader pins</h3>
              <p>
                CoreReader requires version 3, 600-second rounds, nonzero
                genesis and a positive batch limit. Incompatible Core changes
                can stop reads or settlement. The upstream implementation is not
                hash-pinned.
              </p>
            </article>
          </div>
          <div className="risk-bottom">
            <p className="small muted">
              Public RPCs can fail. Rates and pauses are owner-controlled. No
              keeper, guaranteed yield, or real SQK. Use mock assets only.
            </p>
            <a
              className="button"
              href={`${REPO}/blob/main/THREATS.md`}
              target="_blank"
              rel="noreferrer"
            >
              Read THREATS.md <Icon name="external" size={16} />
            </a>
          </div>
        </section>
      </main>
      <footer className="shell site-footer">
        <a href="#top" className="brand">
          <Mark />
          <span>
            SqueekFi <strong>COVER</strong>
          </span>
        </a>
        <p className="small muted">SQI · Sepolia demo</p>
        <nav aria-label="Project resources">
          <a href={JOB} target="_blank" rel="noreferrer">
            Launch job <Icon name="external" size={14} />
          </a>
          <a href={REPO} target="_blank" rel="noreferrer">
            Repository <Icon name="external" size={14} />
          </a>
          <a
            href={`${REPO}/blob/main/THREATS.md`}
            target="_blank"
            rel="noreferrer"
          >
            THREATS.md
          </a>
          <a
            href={`${REPO}/blob/main/LAUNCH.md`}
            target="_blank"
            rel="noreferrer"
          >
            LAUNCH.md
          </a>
        </nav>
      </footer>
    </>
  );
}
