# COVER frontend validation

## Scope and outcome

The static deliverable is complete: source and lockfile in `web/`, production export in `dist/`, implementation notes in `DESIGN.md`, and install/preview/rebuild steps in `README.md`. This is the worker's record, not independent certification. The export is ready for the contributor publisher's IPFS pinning step; no CID or ENS registration was produced here.

The application uses only the supplied Sepolia addresses and repository ABIs. The quote/open, LP deposit/redeem and policy settlement/review panels are implemented. Read-only is the initial state. There are no fabricated balances, seeded production policies, price assumptions or owner operations. Test fixtures are confined to `web/tests/` and are absent from the production export.

Consequential choices: one English dark theme; next eligible round plus one additional round of lead for automatic starts; exact quoted premium as maximum; a five-minute block-time deadline; 0.5% LP output tolerance; raw integer LP shares; a warning when the current round exceeds the frontier by more than three rounds; all-status policy history paginated five at a time with ID lookup. The deployed source's early-settlement and review behavior is explained alongside the requested full-window payout rule.

## Commands and actual results

Commands below are repository-relative equivalents of the commands executed. npm dependencies and browser downloads were installed in temporary staging outside the repository; the same `web/` source and lockfile produced the delivered `dist/`. No generated dependency/cache directory is in the submission.

| Command / check | Actual result |
| --- | --- |
| `forge build --out test/scratch/forge-out --cache-path test/scratch/forge-cache` | Passed with existing Solidity/test warnings. Used to derive ABIs and normalized runtime hashes. No contract source/configuration changes. |
| `npm install --no-audit --no-fund` in isolated frontend staging | Passed; generated the delivered lockfile. Exact versions are pinned in `web/package.json`. |
| `npm run typecheck` | Passed, `tsc --noEmit`, exit 0 after final source formatting. |
| `npm test` | Passed, 5/5 tests; token precision/overflow, integer shares/IDs, all 12 threshold ceil boundaries, future/lead/end limits, positive LP minimums. |
| `npm run build` | Passed, exit 0; final build reported 606ms. Export uses relative asset URLs and contains the local font, favicon, share image, wallet marks, CSS and JS. |
| `npm run check:abis` and `node web/scripts/verify-abis.mjs --artifacts test/scratch/forge-out` (resolved artifact path) | All five canonical ABI hashes match deployment metadata and freshly compiled repository ABIs. |
| `tsx web/scripts/live-check.ts artifacts/live-check.json` | Passed live chain ID, application runtime, immutable dependency and state/rate reads. No signatures or transactions. Evidence copied into `web/validation/live-check.json`. |
| `npm run test:browser` on production export | 10 Chromium scenarios passed; WebKit launch attempted, not run due to missing shared libraries. Actual JSON: `web/validation/browser-validation.json`. |
| Pinned `taste.mjs --out test/scratch/taste` with Playwright explicitly supplied | 15/16 checks passed. The only remaining flag is a reviewed false positive for the required header Connect control. `web/validation/taste-checks.json`. |
| `git diff --check` | Passed. |

Build warnings: the main JS chunk is about 670kB uncompressed / 196kB gzip; dependencies contain client directives; an upstream worker module is externalized for browser compatibility. The loaded production app did not invoke the worker module. Browser inspection found no uncaught JavaScript errors or missing local assets. These warnings are not suppressed.

### Interaction evidence

`web/tests/browser.mjs` serves the built export under `/preview/`, intercepts the supplied RPC endpoints and uses an explicit EIP-6963 provider fixture. It has no signing key and cannot broadcast a transaction. It tests:

1. Responsive widths 320, 390, 768 and 1440px; first-screen CTA at 390; local Inter loading; initial-page axe scan; 200% root-text enlargement without horizontal overflow.
2. Invalid amounts, duration/threshold selection, exact quote calldata, changed-input invalidation, late-response suppression, unconfigured pool/rates and paused opening.
3. RPC-offline placeholders, enabled connection control, honest unavailable states and recovery after Refresh.
4. Phone sheet links/marks, Coinbase Smart Wallet row, full-width geometry and Escape/focus return.
5. Named EIP-6963 discovery, hidden generic row, rejected connection, wrong chain, add-then-switch network flow with the three supplied RPCs, disconnect.
6. Exact premium approval followed by openPolicy, premium ceiling/deadline arguments, confirmed receipt and policy ID decoded from `PolicyOpened`.
7. Deposit preview/approval/execution, 0.5% nonzero minimum shares; redemption with raw integer shares and minimum mSQK assets.
8. Missing-policy lookup, certified settlement, unavailable settlement on unknown history, and permissionless review.
9. Runtime mismatch blocks writes; wallet rejection and reverted receipts do not become success or proceed to opening.
10. Keyboard tab arrows/Home, settlement-gated LP preview, insufficient free liquidity and risk anchor navigation.

Axe with WCAG 2 A/AA, 2.1 AA and 2.2 AA tags reported **zero violations in the checked initial view**. This does not establish full accessibility compliance or replace a screen-reader session. Fixtures exercise receipt success/reversion and wallet rejection; replacement/cancellation and receipt-timeout branches are implemented but were not driven by these browser scenarios.

### Real-chain observation

At **2026-11-01 13:28 UTC**, block **12,041,301**, all five deployed application code checks and immutable address getters matched the build. Reader snapshot returned frontier **1973**, current **2820**, Core unpaused. Pool assets/reserved/free were **0**, open policies **0**, pool binding **not configured**, and all twelve premium rates **unconfigured**.

Separately, the browser used real public RPCs. A quote returned the real `NotConfigured` error, displayed as an actionable owner-activation message. Later screenshots show the clock advancing while frontier remains 1973. These are dated observations, not guaranteed future availability. Opening and LP funding remain unavailable until appropriate owner activation and upstream liveness; the UI does not bypass those conditions. No funded end-to-end transaction or owner action was attempted.

## Better Interface review

The pinned workflow and core principles of all six domains were read and applied during construction, followed by source and rendered review. The final implementation is documented in `DESIGN.md`.

| Domain | Coverage | Evidence and limits |
| --- | --- | --- |
| Accessibility | Checked | Native forms, radio groups, label bindings, live statuses, skip link, tab arrow/Home/End handling, native modal focus containment, Escape/backdrop and focus return. Keyboard interaction and visible Connect focus ring inspected. Axe initial view passed after the definition-list fix. No assistive-technology session; forced-color styles reviewed in source but not rendered. |
| Layout | Checked | Screenshots of 390px first screen and 1440px full page; automation at 320/390/768/1440; no horizontal overflow. CTA bottom at 390 is about 783px in an 844px viewport. Root-text enlargement to 200% passed. Native zoom not tested. English-only scope; RTL/localization not applicable to this assignment. |
| Writing | Checked | Product consistently named COVER; testnet and mSQK/SQI distinction; certified versus unknown rounds; owner-activation, paused, rejection, retry and receipt messages; historical audit findings distinguished from source mitigations. Repeated slogan-style copy removed. |
| Typography | Checked | Local Inter loaded, two font families, three weights and five rendered sizes per measured viewport. Full addresses wrap. Monospace is limited to addresses; data uses tabular figures. No text clipping reported by probe. Native-device font rendering not verified. |
| Colors | Checked | Solid rendered foreground/background pairs measured: text/canvas 16.25:1, secondary/canvas 8.26:1, primary button 12.60:1, warning 9.58:1. Probe text-contrast check passed. Dark theme only; no claim for arbitrary provider icon colors or unmeasured overlay text pairs. |
| UI details | Checked | Flat surfaces, consistent local SVG icons, hover/pressed/disabled states, quote/read loading, empty policy history, recoverable errors, transaction status and explorer links. Motion is limited to 120ms color/border/press transitions guarded by reduced-motion preference. No autoplay or entrance animation; slow-motion timeline review not applicable. |

### Findings, fixes and rechecks

| Severity / domain | Source location | Observation and fix | Recheck |
| --- | --- | --- | --- |
| High / accessibility | `web/src/App.tsx:16` (`Metric`) | Axe found hint paragraphs outside `<dd>` in the dashboard `<dl>`. Moved hints inside each value's `<dd>`; preserved their 14px regular style. | Axe returned zero violations; desktop dashboard re-inspected. |
| Medium / UI | `web/src/Wallet.tsx:80` (`switchNetwork`) | A provider could add Sepolia without selecting it. Added explicit switch after add, then connector reconciliation. Kept switch errors visible when opening the dialog. | Wrong-chain/add-chain fixture passed with all three supplied RPC URLs and correct currency/explorer. |
| Medium / layout | `web/src/styles.css:1396` (mobile `.wallet-sheet`) | Native dialog max-width left a gap at the side of the intended bottom sheet. Reset max-inline-size in the mobile rule. | Phone test measured full viewport width; marks and rows remained visible. |
| Medium / writing | `web/src/App.tsx:479`, `:562`, `:631` | First probe counted repeated short slogans in banner and section headings. Replaced them with direct explanations and task headings. | Slogans check now passes. |
| Medium / accessibility | `web/src/Actions.tsx:111`, `:315`, `:710`, `:898` | Validation needed explicit field relationships and visible recovery. Added described error regions, applicable aria-invalid and error scroll-into-view. | Invalid-precision test checks aria-invalid; rejection/retry tests pass. |
| Low / UI | `web/src/Actions.tsx` (quote, preview and lookup submit buttons) | After a successful preview, both the preview action and next action had filled emphasis. The preview becomes neutral while its result is visible. | Transaction/preview scenarios passed; primary emphasis remains on the next step. |
| Low / data layout | `web/src/App.tsx` (`PolicyList`) | Changing the block key could replace a populated list with a loading message. Retain previous rows while updating and label them “Updating policy activity…”. | Source and interaction review; initial empty live list and populated fixtures both render. |
| Reviewed false positive | `web/src/Wallet.tsx:130` (header control) | Probe calls the required Connect utility above the hero an eyebrow. It is a working header wallet button, not a heading label. Kept it; removing it would violate the wallet requirement. | Confirmed in 390px screenshot; no recurring decorative kicker labels exist. |

The final probe passes render, layout, targets, contrast, casing, tracking, type sizes, type faces, glyphs, slogans, repetition, copy budget, chrome, motion and share metadata. It notes eight controls below the comfortable 44px size; all satisfy its 24px/spacing criterion. Those are secondary text links/disclosures, not the main form actions.

### Rendered evidence

- `web/validation/mobile-390.png`: final production page at 390×844, real RPC state, product and primary action on screen.
- `web/validation/desktop-1440.png`: final full-page production view at 1440px, including the lag warning, real zero balances, contracts and risk section.
- `web/validation/browser-validation.json`: machine-readable scenario outcomes and measured width/CTA/font values.
- `web/validation/taste-checks.json`: actual probe summary.
- `web/validation/abi-verification.json`: all five pinned canonical hashes.
- `web/validation/live-check.json`: dated read-only live chain evidence.

The local preview's initial process expired during documentation work and was restarted before the final screenshots. Error-page captures from that interval were removed; the retained images show the production site.

## Remaining limitations and handoff

WebKit could not start: its launcher reported missing shared libraries, including GStreamer, GTK4, PangoCairo and GDK Pixbuf. Safari behavior is therefore unverified. Physical phone deep links, real installed extensions, Coinbase passkey enrollment, real-wallet transaction signing, screen-reader use, native browser zoom and broad localization were not tested. No claim is made that narrow viewport testing equals device testing.

The runtime application still depends on public Sepolia RPC availability, upstream certification and the deployed owner configuration. The code comparison checks the five application runtimes and their immutable graph against the source; it does not hash-pin the upstream Core implementation. Social preview handling and IPFS/ENS publication can only be checked after a real hosting URL exists. See `THREATS.md` and `LAUNCH.md` for contract risk and activation responsibilities.

Source, runtime assets, source lockfile and static export are retained. There are no package archives, registry mirrors, node_modules, caches, submodules or generated source maps in the submitted frontend. No ignore file was changed, and no existing build/dependency configuration was modified. Final size and asset integrity are recorded in `web/validation/export-inventory.json`.
