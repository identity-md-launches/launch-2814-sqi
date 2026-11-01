# SqueekFi zero-work COVER

A Sepolia-only Foundry application for fixed payouts on certified zero-work rounds. The five contracts are `MockSQK`, `PremiumModel`, `CoverPool`, `CoreReader`, and `PolicyBook`. All dependencies needed by the build and tests are vendored as ordinary source files.

`MockSQK` is the mock collateral called **mSQK** in the brief. Its ERC-20 **name and symbol are SQI**, following the explicit token metadata. It has 18 decimals and an **initial** supply of 100,000,000 tokens, allocated to `$owner`. The requested owner-only faucet can mint more, so that initial supply is not a lifetime cap. There is no second launch token, and real SQK is never accepted or moved.

## Build and check

Run from this directory with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c7cc5695a740dc2fcdde8f1c4d30fed253ff47df6a6c0f59a9813de4f050f02 forge test
forge fmt --check
```

The compiler is version-pinned in `foundry.toml`, with Cancun, optimizer 200 and `bytecode_hash = "none"`. Tests use no network, environment variables, external processes or filesystem permissions. No dependency installation is needed. See [DEPENDENCIES.md](DEPENDENCIES.md) for pinned source provenance.

## Cover rules

| Parameter | Meaning |
| --- | --- |
| `N` / `rounds` | Exactly 6, 12, 24 or 144 ten-minute rounds |
| `T` / `thresholdBps` | Exactly 3000, 5000 or 7000 basis points: 30%, 50%, 70% |
| `startRound` | Must be strictly greater than both the certified frontier and the wall-clock current round |
| `endRound` | `startRound + N - 1`, inclusive; overflow rejected |
| `C` / `cover` | Positive payout amount in mock-token atoms; fully reserved at purchase |
| Beneficiary | The premium-paying caller; fixed and nontransferable |
| Premium | Paid immediately into the LP pool; retained for either outcome |

At settlement, pay **exactly C** when `zeroRounds * 10000 >= N * T`. Otherwise pay zero and release the reservation. For example, a six-round 50% policy pays at three zero-work rounds; a six-round 70% policy needs five. This uses integer cross multiplication and does not truncate the zero-work fraction.

Anyone may call `settle(policyId)` once the frontier is at least `endRound`. The caller gets no reward and cannot redirect the payout. Each policy settles once. There is no cancellation, premium refund, early settlement, expiry by wall-clock timeout, administrative resolution, or input of user-supplied round outcomes. `Expired` means certified settlement without a payout, not a timed refund.

## SqueekCore reads

The immutable external dependency is supplied as `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` on Sepolia in the manifest. `CoreReader` uses the published V3 `state()`, `configuration()`, `implementationCodeVersion()` and `roundPage()` interfaces. The [pinned read ABI](docs/abi/README.md) and [raw public RPC evidence](docs/evidence/sepolia-core-snapshot.json) are included.

The current round is zero before genesis; thereafter it is `floor((block.timestamp - genesisTimestamp) / 600) + 1`. Configuration must report a 600-second duration and 16-record page limit. A frontier covering a current or future round is rejected as inconsistent.

Only active rounds appear in history. Within a **fully certified** window, every omitted round is zero work. Anything after `settledThroughRound` is unknown, regardless of elapsed time or whether a page would omit it. Pages are followed using their returned `certifiedThroughRound`; the reader validates ordering, bounds, work increases, data hashes and continuity of ledger positions. A full 144-round window requires at most nine pages. Read failures and malformed responses revert; they never become zero-work observations.

SqueekCore itself is an externally managed proxy. These five applications have no proxy, upgrade mechanism, delegatecall, write interface into Core, or ability to submit rounds. Core version changes cause reads to fail closed; upgrades that retain version 3 still depend on upstream integrity. [SqueekCore's official interface](https://docs.squeekchain.com/developers/core/) describes its certified-frontier and sparse-page semantics.

## Premiums

No price is invented at deployment. Each of the twelve `(N, T)` entries starts unconfigured; quoting or buying it reverts with `RateNotConfigured` until the owner calls `setRate(N, T, baseBps, slopeBps)`.

Let `A` be accounted pool assets and `R` its existing reservations, before receiving this purchase's premium:

```text
require 0 < C <= A - R
projectedUtilization = (R + C) / A
rateBps = baseBps + ceil((R + C) * slopeBps / A)
premium = ceil(C * rateBps / 10000)
```

`baseBps` must be positive and `baseBps + slopeBps <= 10000`. The slope can be zero. Both rounding steps favor the pool, and a positive cover always costs at least one atom. Each entry can have its own slope. Rates are simple testnet pricing parameters, not a calibrated risk model.

Owner updates affect new purchases only. `openPolicy` re-quotes atomically and enforces the buyer's `maxPremium` and inclusive transaction deadline. Liquidity changes, rate changes or round advancement can invalidate a prior quote. Use a fresh quote and short deadline, with an explicit acceptable premium ceiling. The book holds an exact, temporary allowance to the pool and clears it after use.

## LP accounting

LPs approve the mock token to `CoverPool`, then call `deposit(assets, minShares)`. Internal shares belong to the depositing caller and are nontransferable. `redeem(shares, minAssets)` burns only the caller's shares and pays that caller. Both minimums must be positive.

Assets include deposits and earned premiums, less redemptions and payouts. `reserved` is the sum of all unsettled policies' full cover amounts. A purchase needs enough **pre-premium** free assets; its own incoming premium cannot fund its reservation. Redemption cannot consume reserved assets.

Share conversions use a virtual offset of 1 asset atom and 1,000,000 shares:

```text
deposit shares = floor(assets * (totalShares + 1000000) / (totalAssets + 1))
redeem assets  = floor(shares * (totalAssets + 1) / (totalShares + 1000000))
```

This preserves conversion behavior after complete losses and reduces rounding manipulation. Rounding favors the pool; virtual shares can leave residual assets when all real shares exit. Direct token transfers are **excluded** from accounted assets and cannot inflate the share price. They are irrecoverable donations; use `deposit` to obtain shares. There is no owner sweep or recovery function.

LPs bear correlated cover losses, potentially all deposited capital, and unknown history can lock reservations indefinitely. Share prices use current assets rather than an estimate of future claims. Free-capital withdrawals are permitted even while claims are pending; the remaining reserves still cover every promised payout. There is no yield source, LP withdrawal queue, coverage-per-person limit or economic protection against deliberately selecting correlated windows.

## After launch

The launch owner is `$owner`, resolving to `0xa9cec403edbfd2dfe214258c3c0755b79e60aeac` under this assignment's launch terms. Constructor ownership never goes to the deploying factory. Ownership changes use a two-step handover; renunciation is disabled.

1. Verify the deployment graph and Core compatibility as described in [LAUNCH.md](LAUNCH.md).
2. As owner, call `CoverPool.setPolicyBook(deployedPolicyBook)` **once**, using the address confirmed by the deployment service. This checks reciprocal pool/token wiring. It cannot be rebound, and deposits and new cover are unavailable until binding.
3. As owner, choose the testnet pricing policy and configure the twelve `PremiumModel.setRate` entries. Read each back. Unconfigured entries remain unavailable.
4. Distribute mock collateral from the initial owner allocation, or use owner-only `MockSQK.mint(recipient, amount)` for test funding. LPs supply capital through `deposit`.
5. Buyers obtain quotes, approve the exact premium to `PolicyBook`, and call `openPolicy`. Anyone can manually call `settle` after certification; no keeper is provided or required for authorization.
6. The owner monitors upstream changes and may call `PolicyBook.setPaused(true)` to block new purchases. Core's own pause also blocks new purchases. Neither pause prevents settlement of already certified history or LP redemption of free assets.

See [manifest.json](manifest.json) for the five-contract deployment recipe, [LAUNCH.md](LAUNCH.md) for the operational handoff, and [THREATS.md](THREATS.md) for assumptions and residual risks. No deployment transaction is broadcast by this project.
