# Independent test additions

These tests extend the accepted implementation's suite. Application code, launch files,
configuration and dependencies are unchanged. All imports resolve to the existing vendored
Solidity sources; no network, fork, environment mutation or additional dependency is required.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c7cc5695a740dc2fcdde8f1c4d30fed253ff47df6a6c0f59a9813de4f050f02 forge test
```

The test contracts contain their own fuzz/invariant run counts. The two state machines each
run 256 sequences of 64 calls with unexpected reverts treated as failures. Expected failures
are asserted with their specific error and followed by state checks. Deterministic handler
tests exercise successful transfers, ownership acceptance, payouts, expiry, round trips and
rejected settlements, so a campaign cannot pass solely because its handlers return early.

## Added coverage

| File | Properties and adversarial inputs |
| --- | --- |
| `MockSQKStateMachine.t.sol` | Independent per-actor balances and allowances; supply equals initial allocation plus authorized minting; finite/infinite approval consumption; self/zero transfers; proposal replacement/cancellation and two-step ownership; unauthorized mint/admin calls; revocation; invalid recipients; full initial supply and uint256 supply boundary. |
| `PolicyFailureMatrix.t.sol` | All twelve products at one zero below, exactly at, and one zero above their trigger; old quotes crossing a clock boundary; insufficient balance after approval; donated book balances; snapshot failures; second-page failure and retry; frontier one short; terminal expiry replay; withdrawal and settlement under both pauses. |
| `CoreReaderProperties.t.sol` | A 144-round count equals the sum of supported 24- and 6-round subwindows, with independent mask-based counts and work outside the window; clock boundaries; malformed ledger fields and oversized pages; bad configuration cannot consume premiums or IDs. |
| `PremiumArithmeticProperties.t.sol` | 1,000 runs per fuzz property; full uint256 utilization with an independent quotient/remainder oracle; least-integer bounds on both rounding steps; more capital cannot raise the same cover's price; unsupported terms; failed rate updates preserve the old rate. |
| `SolvencyInvariant.t.sol` | Extended existing handler with repeated deposit/redemption cycles, repricing, early/replayed settlement attempts and transfers. Added immutable purchase-history ghosts, expected terminal states, zero counts, total token conservation and aggregate redemption-claim bounds. |

The threshold matrix pins minimum zero counts independently:

| N | 30% | 50% | 70% |
| --- | ---: | ---: | ---: |
| 6 | 2 | 3 | 5 |
| 12 | 4 | 6 | 9 |
| 24 | 8 | 12 | 17 |
| 144 | 44 | 72 | 101 |

## Invariant discovery and evidence

The five supplied Pashov discovery passes were performed locally, followed by the Trail of
Bits checks for vacuous generators, incorrect properties and implementation-shaped oracles.
No subagents were used. The retained guarantees are specific to this implementation; the
pool is not assumed to implement ERC-4626.

| Discovery pass | Evidence and resulting properties |
| --- | --- |
| Conservation | `src/CoverPool.sol:100`, `:115`, `:131`, `:151`: deposits/premiums minus withdrawals/payouts equal accounted assets; reserves equal open obligations; tracked LP shares sum to total shares. `src/MockSQK.sol:12`, `:17`: supply and balances reconcile through authorized minting and transfers. |
| State transitions | `src/PolicyBook.sol:112`, `:148`: successful purchases allocate exactly one ID, fix terms and beneficiary, then terminate once as Paid or Expired; rejected calls preserve those states. Price changes do not rewrite old terms. |
| Round trips and rounding | `src/CoverPool.sol:92`, `:96`: repeated immediate deposit/redemption cycles cannot increase the caller's token balance, including after premiums and claims. `src/PremiumModel.sol:38`: both divisions round upward, without overflowing valid uint256 quotes. |
| Adversarial value/liveness | Unpaid premiums, stale quotes, paused opening, unavailable/malformed Core pages and replay attempts must fail without consuming assets or reservations. Repeated complete losses exposed the separately reported share-growth defects. |
| Protocol-specific | `src/CoreReader.sol:56`: only fully certified windows are countable, each missing record contributes one zero and work magnitude is irrelevant. Payouts use the inclusive integer thresholds above. Token allowances/ownership are checked against independent ledgers. |

The accounting model deliberately distinguishes premiums from collateral and direct token
donations from accounted pool assets. LP withdrawals may earn premiums and claims may reduce
LP value; neither a fixed share price nor a fixed post-launch token supply is asserted.

## Reported defects and limits

The two share-supply defects reported in the previous round (a deposit overflowing
`totalShares + VIRTUAL_SHARES`, and worthless shares blocking recapitalization) were fixed by the
implementation (`MAX_TOTAL_SHARES`, share epochs) and are covered by its `ShareSupply.t.sol`; the
invariant still asserts the bounded share denominator.

This revision reports two new items in the repository-root `.imd-findings.json`:

1. **Medium (with proof):** `settlementPending()` probes only `snapshot()`. When Core `roundPage`
   fails or is rejected for a certified window, `settle` cannot run but the gate stays closed, so
   every deposit and free-liquidity redemption reverts `SettlementPending` indefinitely. The
   documentation says the gate fails open when the core cannot be read.
2. **Low:** one-atom cover is accepted for a one-atom premium; each such policy must be settled
   before LPs can move once its window is certified (`test_dustPoliciesMustEachBeSettledBeforeLpsCanMove`).

To reproduce the medium finding, extract its `proof` verbatim to a temporary
`test/scratch/*.t.sol` file and run `forge test --match-path` on it; it fails on the current code.

## Revision for the settlement gate, lead cap and batch-limit changes

- `SolvencyInvariant.t.sol`: `roundTrip` asserts both LP paths revert `SettlementPending` while a
  certified policy is unsettled; a new invariant compares `openPolicyCount`, `earliestOpenEnd` and
  `settlementPending` with a naive scan of all policies after every call.
- `SettlementGateAdversarial.t.sol`: dust policies, later uncertified windows not blocking, both
  pauses not hiding a pending settlement, check order (shares/amount before the gate), and a fuzzed
  settlement order checked against the naive minimum.
- `CoreReaderProperties.t.sol`: a batch limit other than 16 is no longer invalid; a fuzz test checks
  any positive limit yields the same zero count. Invalid configuration cases are now genesis 0,
  round duration 599/601 and batch limit 0.
- `PolicyFailureMatrix.t.sol`: the 36-window matrix (1,674 rounds) now advances the clock so each
  window starts inside `MAX_LEAD_ROUNDS`.

The ordinary invariant campaigns exercise bounded random sequences, not every possible
sequence. Their success does not negate these deterministic failures. The Core fixture
models valid sparse certified history; it does not prove the live Sepolia Core's current
configuration, liveness, governance or truthfulness. No fork block/RPC variable was specified
for this assignment. Existing recorded-ABI tests remain offline compatibility checks.

Root deployment documentation and manifest belong to the accepted implementation and were
not changed by this tests-only assignment. This suite does not approve a launch with the
reported defects unresolved.
