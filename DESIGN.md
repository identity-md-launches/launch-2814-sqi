# COVER design system

## Overview

COVER is a technical, read-first Sepolia demo for SqueekFi. The visual idea is a quiet contract console: a graphite canvas, a compact quote form and a six-round diagram. The diagram is explicitly illustrative. Actual pool values come from RPC reads and have a block reference; unavailable values never become zero.

The source of truth is `web/src/styles.css`. Page composition lives in `web/src/App.tsx`; transactional panels live in `web/src/Actions.tsx`. This is one dark theme, in English. The frontend does not change any contract economics or owner configuration.

## Colors

Components use semantic variables referencing the primitive palette in `:root`.

| Token | Value | Role |
| --- | --- | --- |
| `--bg` | `#111411` | Canvas and input background |
| `--surface` | `#191d19` | Action panel, wallet sheet, empty state |
| `--hover` | `#202620` | Hover and selected neutral surfaces |
| `--line` | `#2a322a` | Structural separators |
| `--control-line` | `#657061` | Input and button boundaries |
| `--muted` | `#a6b0a1` | Secondary text and explanatory labels |
| `--text` | `#eef1e9` | Primary text |
| `--accent` / `--focus` | `#c2ef87` | Primary action fill and keyboard focus |
| `--accent-hover` | `#d0f5a6` | Primary button hover |
| `--on-accent` | `#16220d` | Primary button text |
| `--warning` / `--warning-bg` | `#f1c47a` / `#292319` | Lag and risk notices |
| `--error` / `--error-bg` | `#ffb8aa` / `#30221e` | Recoverable errors |

Measured from the rendered production page: text/canvas 16.25:1, secondary text/canvas 8.26:1, primary button 12.60:1, warning 9.58:1. See `VALIDATION.md` for coverage and limitations. Status always has text in addition to color. The brand mark uses the accent as a deliberate brand exception; decorative round history stays neutral.

## Typography

Inter is bundled locally in `web/src/inter-latin.woff2` (Fontsource Variable Inter 5.3.0, Latin normal variable face). The file supplies weights 100–900; the interface uses only 400, 500 and 600. Fallbacks are system UI, Apple system, BlinkMacSystemFont, Segoe UI, sans-serif. Addresses use the system monospace stack. No italic face is requested.

| Token | Size | Use |
| --- | --- | --- |
| `--text-sm` | 0.875rem / 14px | Labels, metadata, help, buttons |
| `--text-base` | 1rem / 16px | Body copy and inputs |
| `--text-lg` | 1.25rem / 20px | Panel titles, tertiary headings, desktop hero description |
| `--text-section` | 1.75rem / 28px | Section headings, pool values, amount input |
| `--text-title` | 2.5rem / 40px | Narrow hero headline |
| `--text-display` | 4rem / 64px | Wide hero headline |

Only five sizes render at either measured 390px or 1440px width. Body line height is 1.5–1.6; headings are 1.07–1.3. Display tracking is −0.055em, narrowing to −0.04em below 66rem; section headings use −0.025em. Body text has natural tracking. Heading wrapping uses `balance`, prose uses `pretty`, long prose is bounded around 70ch. Numeric data uses tabular figures. Addresses wrap and remain fully selectable; connected-wallet abbreviation expands to a full address in the sheet. Mobile inputs are at least 16px.

## Layout

The `.shell` has a 1200px maximum outer width, centered, with 32px gutters. Spacing tokens are 4, 8, 12, 16, 24, 32, 48, 64 and 96px. Controls commonly use 8–12px gaps; related content 16–24px; major sections 48–64px. Directional spacing uses logical properties.

The desktop hero has two columns (1.1fr/1fr), with a 72px gap. The left column explains COVER; the right is the working action panel. Dashboard metrics form a three-column grid. Contract addresses are full text links with a separate copy button. Explanatory steps and risks use three columns without nested cards.

| Breakpoint | Implemented behavior |
| --- | --- |
| ≤66rem / 1056px | Hero gap becomes 40px and title becomes 40px; footer resources wrap |
| ≤48rem / 768px | Single-column hero; hide desktop nav and illustrative diagram; gutters 24px; metrics two columns; steps and risks stack; contracts wrap |
| ≤30rem / 480px | Gutters 20px; compact 32px banner and 76px header; action padding 20px; units stack under metrics; wallet dialog becomes a full-width bottom sheet |

At 390×844, the product, wallet control, terms and complete Get quote button are visible on the first screen (button bottom approximately 824px in the current export). At 320px there is no horizontal overflow. The action panel is at most 560px on narrow/tablet layouts. Content scrolls normally; no sticky chrome covers it. Tested widths are 320, 390, 768 and 1440px. A 200% root-text enlargement check passed; native browser zoom was not tested.

## Elevation & depth

There are no box shadows, gradients or animated entrances. Tonal surfaces and 1px borders communicate grouping. The native modal uses the top layer and a black 72% backdrop; the background is inert while it is open. The skip link has z-index 20. This flat hierarchy is intentional.

## Shapes

`--radius` is 8px for controls and notices; `--radius-panel` is 16px for panels and desktop dialogs. Status tags and round blocks use 6px. Round status dots are circular. Focus uses a 2px solid accent outline offset 4px; radio focus uses a 3px offset. Forced-color mode substitutes system Highlight and ButtonText. Avoid clipping text to maintain the rounded shape.

## Components

- **Buttons and links** (`styles.css`): `.button`, `.primary`, `.full`, `.subtle`, `.icon-button`, `.text-button`. Primary buttons are at least 48px tall; other main controls are 44px. A preview turns neutral once a result exposes the next primary action. Disabled buttons remain visibly distinct. Hover is gated by pointer capability. Press scale is 0.96 with 120ms transitions only when reduced motion is not requested.
- **ActionPanel** (`Actions.tsx`): three real tabs with roving focus, arrow keys and Home/End. Cover uses native radio groups for the four windows and three thresholds. Labels are persistent. Errors are inline live alerts, connected to their fields, and scrolled into view. Input changes invalidate results; late quote responses cannot overwrite newer input.
- **Review and WalletGate** (`Actions.tsx`): show exact premiums, inclusive rounds, output minimums and expiry. Risks require acknowledgement. Exact token approval is a separate action; there is no unlimited approval. Read-only previews work before connection. Wrong-chain and failed-deployment states explain why a write is unavailable.
- **WalletControl** (`Wallet.tsx`): native dialog, close button, Escape/backdrop dismissal, focus return. Named EIP-6963 providers come first. Phone browsers without a provider get four wallet-browser links and Coinbase Smart Wallet. Rows use local official wallet marks or provider icons. Pending, rejection, connected and wrong-chain states are explicit.
- **Metric and LiveDashboard** (`App.tsx`): semantic definition list, full values, block/time context, partial-read notices, stale-state indication and a lag warning beyond a three-round clock/frontier gap. Refresh does not require a wallet. The `paused` prop receives React Query's `isPaused`: paused reads show “Offline”, “Live reads paused” and “You are offline. Reconnect, then retry.” in the existing `notice error` region. The enabled Retry button uses `.button.failed` and `aria-describedby="live-error"`; cached values are identified as the last successful read. Active reads retain their eight-second deadline and disabled loading control. Policy activity is paginated and labels all statuses; it never claims to list every open policy on one page.
- **TransactionStatus** (`transactions.tsx`): persistent on-page progress and explorer links for pending, confirmed, reverted or unconfirmed receipts. Unknown receipt status is not success. Account/chain are rechecked before simulation and sending. Successful policy IDs come from receipt events.
- **Icon and Mark** (`Icons.tsx`): local SVG outlines at 1.7px stroke, using `currentColor`; decorative icons are hidden from accessibility APIs. No icon package or raster hero asset is needed.

## Do's and don'ts

Use `.shell`, the existing spacing variables and section/grid primitives when adding content. Reuse the button hierarchy and existing notice roles. Keep all data on its correct chain and show its provenance. Use raw integer units for LP shares and 18 decimals only for mSQK. Preserve whole addresses, exact review amounts and clear unknown/error states.

Do not add estimated pool balances, yield claims, fiat TVL, external font requests or unlabeled sample history. Do not turn the neutral diagram into a live chart unless it reads certified history. Keep new wallet and contract behavior in the existing configuration and transaction modules.

The page was built and reviewed against the pinned six-domain Better Interface guidance. Guidance attribution: Jakub Krehel, Better Interface (MIT), commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`; documentation structure adapted for this implemented site from Paul Bakaus, Impeccable (Apache-2.0), commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`. Retained licenses are in `web/licenses/DESIGN-GUIDANCE.txt`; sources and asset notices are in `web/ATTRIBUTIONS.md`.
