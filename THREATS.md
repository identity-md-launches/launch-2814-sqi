# Threat model and review notes

## Scope and trust

This is a Sepolia application using owner-mintable mock collateral. It reads certified SqueekCore work history and promises a fully reserved fixed cover payout. No real SQK, native-ETH payments, swaps, external investment strategies, proxies, upgrades, core submissions, keepers or UI are included.

The protected inputs supplied with the assignment exercise deployment structure and ownership. They do not establish correctness of cover accounting. The delivered tests separately exercise behavior, failure paths and asset conservation. Tests and this implementation review are not an independent audit.

| Trust boundary | Power or assumption | Consequence |
| --- | --- | --- |
| SqueekCore Reporter/governance | Certifies history and controls the existing external proxy | Incorrect but well-formed data can determine payouts; history integrity cannot be independently proved by this application |
| Core liveness | Advances `settledThroughRound` | If it stops, open policies may retain their reservations forever |
| Core ABI/version | V3 structs and sparse pagination remain compatible | Unsupported versions, bad configuration or malformed reads revert; existing policies can become unresolvable |
| Launch owner | Mints mock collateral, sets new-policy prices, pauses opening and performs one-time pool binding | Owner must choose prices and the correct book before users fund the pool; mock-token economics depend on the owner |
| Fixed collateral | Deployed `MockSQK` uses ordinary ERC-20 balance/allowance semantics | Rebasing, taxed, blocklisting or callback tokens are not launch assets; no general multi-token support is claimed |
| LPs | Provide the whole maximum payout in advance | They absorb correlated claims and may lose all capital |
| Buyers | Select allowed future windows, size and threshold | No restriction prevents many correlated policies or very distant start rounds |
| Settlement callers | Pay gas to call a permissionless function | No scheduled job or reward guarantees that someone calls promptly |

`$owner` receives no premium skim, payout authority, collateral sweep or ability to override an existing policy. The pool's book address can be bound once, after reciprocal pool/token checks, and never replaced. The owner's price setter can make new cover economically unattractive but cannot change old premiums, windows, thresholds, cover sizes or beneficiaries. Ownership handover is two-step and renunciation is disabled. Binding a malicious contract with matching getters is still possible for an owner before activation; LPs must verify the deployed bytecode and links before depositing.

## Defenses and failure behavior

- **Unknown history:** settlement checks the frontier before reading the entire policy window. Clock passage alone cannot establish zero work, trigger a payout, or free the reservation. Tests cover a frontier one round short even after ten years.
- **Sparse history:** pages are counted through the returned certification cursor. Bounded record count, increasing IDs, range checks, positive cumulative-work deltas, nonzero data hashes and consistent positions prevent accidental omissions or duplicate counting. Missing records within certified history are zero-work rounds. There is no per-round write or keeper-maintained cache.
- **Limits and arithmetic:** only four durations and three thresholds are allowed. End-round arithmetic is checked before narrowing. Payout thresholds use cross multiplication; pricing and LP share conversion use full-precision `Math.mulDiv`. No large user-controlled settlement loop exceeds 144 active records / nine valid pages.
- **Full reserves:** `reserved` equals the sum of unsettled cover amounts, and `totalAssets >= reserved`. Deposits, earned premiums, withdrawals and payouts have explicit accounting. Incoming premium cannot provide its own policy's collateral. Withdrawals cannot consume reserved assets.
- **LP rounding and donations:** virtual assets/shares handle initial funding and complete losses. Rounding favors the pool. Unsolicited transfers are excluded from NAV; minimum shares/assets protect users from price movement. There is no recovery of donations or residual rounding assets.
- **Reentrancy:** book and pool value-changing methods are guarded with OpenZeppelin `ReentrancyGuard`. Policy status and reserve/accounting changes precede payout calls. Callback-token tests attempt nested opening, deposit, redemption and settlement.
- **Transfer failures:** `SafeERC20` handles false and missing return values. Both inbound premium legs and deposits require the exact amount received; outgoing pool balance changes must match accounting. All state rolls back on failure, preserving the reservation and allowing retry. The actual launch token is fixed and has no transfer tax or callback.
- **Allowance/custody:** tokens are pulled only from `msg.sender`, with an exact book-to-pool allowance cleared after purchase. The payer is the fixed beneficiary. No function exposes arbitrary external execution or transfers from another approved user.
- **Transaction ordering:** buyers specify a premium ceiling and deadline; LPs specify minimum shares/assets. Rates and utilization can change before inclusion. The start round is revalidated at execution, preventing purchases for the current round after a delayed transaction.
- **Pause scope:** either local or Core pause blocks new purchases. Settlement of certified policies and withdrawal of free capital remain possible. A pause cannot halt an already certified payout.

The upstream external proxy can still fabricate consistent V3 responses or exhaust gas. The reader's structural checks detect malformed responses, not malicious truth claims. An unchanged version number also does not authenticate implementation code. Verify Core implementation identity and governance before activation, then monitor upstream changes.

## Economic and operational limitations

There is no actuarial calibration, dynamic probability model, position limit or anti-selection mechanism. The owner must choose the twelve price entries. Full collateralization guarantees accounting capacity under the token/Core assumptions, not LP profitability. The same physical zero-work event may trigger every outstanding policy.

Premiums immediately belong to LP assets. Share prices do not discount unresolved claims. LPs can withdraw free liquidity while other capital remains reserved; late deposits participate in future losses. Virtual shares and rounding may retain dust, especially after extreme loss and recapitalization. User minimum outputs and previews are necessary for sensible transaction construction.

A policy may start arbitrarily far into the future, subject to uint64 bounds. There is no automatic timeout or cancellation; reserving such a policy can lock liquidity for that whole period, plus any oracle delay. Add no operator refund workaround: doing so would change the agreed certified-history payout semantics.

The public Core snapshot captured for this project had frontier 1973 with a later current round. It is evidence that wall-clock time and certification must be treated separately, not an uptime guarantee. Users and LPs should inspect live frontier progress before participating.

## Verification performed

The delivered suite includes all-term threshold fuzzing, sparse/dense 144-round history, raw recorded Sepolia ABI responses, malformed pages, configuration and authorization failures, time/round boundaries, overlapping policies, reverse settlement order, premium slippage, LP donation resistance, complete loss and recapitalization, transfer failures, replay protection, pauses, reentrancy, constructor rehearsals and runtime opcode/size checks.

Stateful invariants interleave LP actions, purchases, donations, clock advances, certification and settlements. They assert:

```text
reserved = sum(C for open policies)
totalAssets >= reserved
pool token balance = totalAssets + unsolicited donations
totalAssets + total withdrawals + total payouts
    = initial LP capital + later deposits + all collected premiums
totalShares = sum(shares held by the tracked LPs)
```

The manual implementation review traced each external write function, every token transfer, boundary arithmetic and all external Core reads. Adversarial tests were added for the concrete failure paths above. Neither Slither nor Mythril was run. No funded transaction was signed or broadcast. The recorded RPC fixture is an offline compatibility test, not an end-to-end live deployment test. An independent adversarial review and a small Sepolia activation rehearsal remain release responsibilities.
