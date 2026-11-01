# SqueekFi zero-work COVER

A Sepolia-only Foundry application and static COVER demo for fixed payouts on certified zero-work rounds. The five contracts are `MockSQK`, `PremiumModel`, `CoverPool`, `CoreReader`, and `PolicyBook`. Contract dependencies are vendored as ordinary source files; the frontend uses the npm lockfile in `web/`.

`MockSQK` is the mock collateral called **mSQK** in the brief. Its ERC-20 **name and symbol are SQI**, following the explicit token metadata. It has 18 decimals and an **initial** supply of 100,000,000 tokens, allocated to `$owner`. The requested owner-only faucet can mint more, so that initial supply is not a lifetime cap. There is no second launch token, and real SQK is never accepted or moved.

## Static demo website

The deployable export is **[dist/index.html](dist/index.html)**, with complete relative assets in `dist/`. Frontend source, its own package manifest and reproducible lockfile live in [web/](web/). The stack is Vite, React, TypeScript, viem, Wagmi and TanStack Query; the existing Foundry configuration is separate.

### Install, preview and rebuild

Use Node.js 22.12+ (or 24+) and npm:

```sh
cd web
npm ci
npm run typecheck
npm test
npm run build
npm run preview -- --port 4173
```

Open the local URL printed by preview. `npm run build` replaces the repository-root `dist/`. For development use `npm run dev`. For a plain static preview from the repository root, `python3 -m http.server 4173 --directory dist` also works. No backend, environment file, private key, wallet project ID or API token is needed.

The export uses `base: './'`, hash anchors and local fonts, icons and share image. Serve the **contents of `dist/`** at the hosting root or any gateway subpath. The contributor publisher can pin this exact folder to IPFS after submission. This run produced the export; it did not publish a CID or register an ENS name. Social-image URL resolution remains dependent on the eventual gateway/crawler.

Keep `node_modules`, browser downloads and package caches out of submissions at every depth. They are not included here. No ignore file was changed. No npm tarballs or vendored registry are needed for offline verification.

### Using COVER

The default page reads Sepolia without a wallet. Choose cover amount, duration and threshold, then **Get quote**. Automatic start is two rounds after the greater of current round and frontier; an optional manual start is limited by the contract's 1,008-round lead cap. A quote uses the actual `PolicyBook.quote`, has a five-minute deadline from the latest block, and sets its exact premium as the maximum. Changed inputs invalidate it.

Connect through the header when ready to transact. Desktop providers are discovered by EIP-6963; phone browsers offer MetaMask, Coinbase Wallet, Rabby and Phantom deep links. Coinbase Smart Wallet uses its SDK without a relay/project ID. Wrong-chain transactions remain unavailable; the wallet control switches/adds Sepolia using the supplied network parameters. Previously authorized connections can reconnect through Wagmi storage.

Opening and deposits separate **Approve mSQK** from the subsequent action. Allowances are exact, not unlimited. The Liquidity panel previews deposits and redemptions with a 0.5% minimum-output tolerance and checks the share epoch. Shares are **raw integer units**, not 18-decimal token balances. The Settle panel looks up any policy, shows the holder and certified progress, and offers permissionless settlement or review. Review is useful when the LP gate needs maintenance. Every write is simulated first; pending, replacement, reverted and unconfirmed receipts have explicit states and Sepolia explorer links.

mSQK is the UI name of MockSQK collateral; its deployed ERC-20 symbol is **SQI**, with 18 decimals. Only its owner can mint it. Sepolia ETH is separately needed for gas. The UI neither mints tokens nor activates owner settings.

### Deployment and observed availability

All six addresses and the three supplied public RPC endpoints are centralized in [web/src/config.ts](web/src/config.ts). The five application ABIs were compiled from source commit `e4e6668ad2dd701ce96e96160c2e316bb68d38f3`; every canonical Keccak ABI hash matches [web/deployment.json](web/deployment.json). The browser compares application runtime bytecode against the compiled source with immutable slots normalized, then checks each immutable address getter. These checks run before wallet writes as well as on page load. SqueekCore is read-only, with no write ABI exposed.

At the recorded live check on **2026-11-01 13:28 UTC**, block **12,041,301**, all app code/dependency checks passed. Core frontier was **1973**, clock round **2820**, and the pool's assets, reserves and open policies were all **zero**. The pool was **not bound to PolicyBook**, and all twelve premium rates were **unconfigured**. The UI reports these states honestly. Activation and Core liveness remain the existing owner's operational responsibility under [LAUNCH.md](LAUNCH.md); no activation or funded transaction was attempted.

### Website checks actually run

- Production build and TypeScript check passed; five unit tests passed, including exact amounts, all twelve threshold boundaries, start bounds and nonzero LP minimums.
- Ten Chromium interaction scenarios passed against the production export at a `/preview/` subpath: reads/offline retry, forms, wallet discovery/rejection/network switching, exact approvals, open/deposit/redeem/settle/review calldata, receipt handling, code mismatch gating, keyboard and mobile layout. These use explicit offline fixtures; no real transaction is signed.
- Real Sepolia reads, an activation-blocked quote and production mobile/desktop screenshots were also inspected separately. Axe reported zero violations in the checked initial view. No horizontal overflow at 320, 390, 768 or 1440px, including the separate 200% root-text enlargement check.
- The pinned taste probe passed 15/16 checks. Its one remaining flag mistakes the required header Connect button for a heading kicker; visual inspection confirmed a normal wallet utility. The repeated-copy finding and applicable accessibility/UI defects were fixed.
- WebKit was attempted but could not launch because required shared libraries are missing. Native mobile wallets, real passkeys, screen-reader sessions and native browser zoom were not tested. No production safety claim is made.

Build warnings concern a 670kB main JavaScript chunk (about 196kB gzip), client-only directives in dependencies, and an externalized unused worker module in an upstream dependency. Chromium loaded the production assets without console or missing-resource errors.

See [VALIDATION.md](VALIDATION.md) for commands, the six-domain review, findings and coverage limits, [DESIGN.md](DESIGN.md) for implemented tokens/components, and [web/validation/](web/validation/) for recorded evidence. This is worker validation, not independent certification.

To repeat the browser scenarios on a system with browser dependencies installed:

```sh
cd web
npx playwright install chromium webkit
npm run test:browser
npm run check:abis
npx tsx scripts/live-check.ts ../artifacts/live-check.json
```

The last command reads the real public RPCs; it sends no transactions. The browser fixture suite is offline. To compare ABIs directly to a fresh Foundry build, run from the repository root:

```sh
forge build --out test/scratch/forge-out --cache-path test/scratch/forge-cache
cd web
npm run check:abis -- --artifacts ../test/scratch/forge-out
```

## Contract build and check

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
| `startRound` | Strictly greater than both the certified frontier and the wall-clock current round, and at most `MAX_LEAD_ROUNDS = 1008` rounds (seven days) after the current round |
| `endRound` | `startRound + N - 1`, inclusive; overflow rejected |
| `C` / `cover` | Positive payout amount in mock-token atoms; fully reserved at purchase |
| Beneficiary | The premium-paying caller; fixed and nontransferable |
| Premium | Paid immediately into the LP pool; retained for either outcome |

At settlement, pay **exactly C** when `zeroRounds * 10000 >= N * T`. Otherwise pay zero and release the reservation. For example, a six-round 50% policy pays at three zero-work rounds; a six-round 70% policy needs five. This uses integer cross multiplication and does not truncate the zero-work fraction.

Anyone may call `settle(policyId)` once the frontier is at least `endRound`, and earlier as soon as certified history has fixed the outcome: the certified prefix of the window already holds `ceil(N * T / 10000)` zero-work rounds (paid for certain) or so many active rounds that the threshold can no longer be reached (expired for certain). Only certified rounds are ever counted; an early decision is one that no later certified round can change, and `zeroRounds` on the settled policy is the count in the certified prefix at that moment. Until then `settle` reverts `Undecided(policyId, zeroRounds, certifiedRounds)`. The caller gets no reward and cannot redirect the payout. Each policy settles once. There is no cancellation, premium refund, expiry by wall-clock timeout, administrative resolution, or input of user-supplied round outcomes. `Expired` means certified settlement without a payout, not a timed refund.

The lead cap bounds how long one premium can keep LP capital reserved before the core is even able to certify the window: a policy opened today ends within `1008 + 144` rounds of the current round. The value is a named constant chosen for this launch, not a brief parameter; it has no owner setter.

Every open policy carries a **decide round**: the earliest round whose certification could fix its payout. It starts at `startRound + ceil(N * T / 10000) - 1`. While the frontier is at or past the smallest decide round of any open policy, the book reports `settlementPending() == true` and the pool refuses deposits and redemptions: a payout that public history has already fixed always belongs to a policy at or below that round, so nobody trades at a share price the history has made stale. `earliestDecideRound()` names the round and `openPolicyIdsDecidingAt(round)` lists the open ids there. For each, anyone (including the blocked LP) calls `settle` if the outcome is fixed, or `review(policyId)`, which settles it when it is and otherwise moves its decide round to the earliest round at which the threshold could still be met (last certified round plus the zero rounds still missing). After that the gate is open again until the frontier reaches the new round. Each call reads the certified prefix once, at most nine pages. `earliestOpenEnd()` and `openPolicyIdsEndingAt(endRound)` remain available for callers who settle by window end. The gate fails open when the core's metadata or history cannot be read, because nothing can settle or be reviewed in that state either; it checks that by reading the pending policy's history only on the already-blocked path.

## SqueekCore reads

The immutable external dependency is supplied as `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` on Sepolia in the manifest. `CoreReader` uses the published V3 `state()`, `configuration()`, `implementationCodeVersion()` and `roundPage()` interfaces. The [pinned read ABI](docs/abi/README.md) and [raw public RPC evidence](docs/evidence/sepolia-core-snapshot.json) are included.

The current round is zero before genesis; thereafter it is `floor((block.timestamp - genesisTimestamp) / 600) + 1`. Configuration must report a 600-second duration, a nonzero genesis and a positive batch limit. Pages are requested at `min(16, maxRoundsPerBatch)` records, so a core that raises its limit is read exactly as before and one that lowers it is paged in smaller steps; neither change can strand a certified settlement. A frontier covering a current or future round is rejected as inconsistent.

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

The surcharge is charged at the utilization the purchase itself reaches, on the whole amount. It is therefore not path independent: the same cover bought in several smaller policies pays roughly half the surcharge component (the integral of a linear price instead of its endpoint). Owners who want a firm price per unit of cover should rely on `baseBps` and set `slopeBps` to zero; the slope is a soft deterrent against draining liquidity in one purchase, not a volume price.

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

The share supply is bounded: `totalShares` never exceeds `MAX_TOTAL_SHARES = 2^256 - 1 - 1000000`, so `totalShares + 1000000` always fits and `previewRedeem` can never overflow. A deposit whose shares would not fit is handled in one of two ways:

- If accounted assets are at most `RETIRE_DUST = 1,000,000` atoms (10^-12 of one token), the outstanding shares are worth at most that dust in total. The pool retires them by starting a new share epoch (`shareEpoch` increments, `SharesRetired(epoch, shares, dustCarried)` is emitted, `totalShares` resets), keeps the dust in accounted assets for the new epoch, and mints the deposit against the empty supply. Retired shares read as zero through `sharesOf` and remain visible through `sharesOfEpoch(epoch, lp)`. Retirees lose at most the dust, which backs the new epoch's virtual shares.
- If accounted assets are **above the dust bound**, nothing is retired and the deposit reverts with `ShareSupplyExhausted`. `previewDeposit` reverts the same way. The remaining holders keep redeeming; once they take the value down to dust, the next deposit retires the supply.

Repeated complete losses are the only way to reach that bound. Each recapitalization after a total loss multiplies the supply by the deposit size in atoms, so about three such cycles exhaust it; the retirement rule makes the pool recapitalizable afterwards instead of permanently stuck, and the dust bound keeps one atom placed by anyone, or left by redeem rounding, from disabling it.

LPs bear correlated cover losses, potentially all deposited capital, and unknown history can lock reservations indefinitely. Share prices use current assets rather than an estimate of future claims. Free-capital withdrawals are permitted while claims are pending and certified history has not yet fixed them; the remaining reserves still cover every promised payout. Once the frontier reaches an open policy's decide round, deposits and redemptions wait for its settlement or review (see the cover rules above). There is no yield source, LP withdrawal queue, coverage-per-person limit or economic protection against deliberately selecting correlated windows.

## After launch

The launch owner is `$owner`, resolving to `0xa9cec403edbfd2dfe214258c3c0755b79e60aeac` under this assignment's launch terms. Constructor ownership never goes to the deploying factory. Ownership changes use a two-step handover; renunciation is disabled.

The contracts target Sepolia (chain id 11155111) by launch policy, not by code: constructors make no external calls and do not read the chain id, so the launch's empty-chain rehearsal deploys them unchanged. On any other chain the pinned core address has no code and every quote and settlement fails closed with `CoreUnavailable`.

1. Verify the deployment graph, the **live** certified frontier and Core compatibility as described in [LAUNCH.md](LAUNCH.md). Do not bind the book or invite LP deposits while the frontier is stalled.
2. As owner, call `CoverPool.setPolicyBook(deployedPolicyBook)` **once**, using the address confirmed by the deployment service. This checks reciprocal pool/token wiring. It cannot be rebound, and deposits and new cover are unavailable until binding.
3. As owner, choose the testnet pricing policy and configure the twelve `PremiumModel.setRate` entries. Read each back. Unconfigured entries remain unavailable.
4. Distribute mock collateral from the initial owner allocation, or use owner-only `MockSQK.mint(recipient, amount)` for test funding. LPs supply capital through `deposit`.
5. Buyers obtain quotes, approve the exact premium to `PolicyBook`, and call `openPolicy`. Anyone can manually call `settle` once certified history fixes the outcome, at the latest when the frontier reaches the end round; no keeper is provided or required for authorization. LPs who hit `SettlementPending` call `review` (or `settle`) on the ids listed by `openPolicyIdsDecidingAt(earliestDecideRound())` first, then retry.
6. The owner monitors upstream changes and may call `PolicyBook.setPaused(true)` to block new purchases. Core's own pause also blocks new purchases. Neither pause prevents settlement of already certified history or LP redemption of free assets.

See [manifest.json](manifest.json) for the five-contract deployment recipe, [LAUNCH.md](LAUNCH.md) for the operational handoff, and [THREATS.md](THREATS.md) for assumptions and residual risks. No deployment transaction is broadcast by this project.
