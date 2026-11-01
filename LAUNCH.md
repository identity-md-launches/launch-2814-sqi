# Sepolia deployment and activation handoff

This deliverable supplies source, offline tests and [manifest.json](manifest.json). The deployment service creates its authoritative `launch.json` in the separate manifest step; this repository deliberately supplies no `launch.json`, broadcast script, private key configuration or predicted application addresses.

## Fixed deployment parameters

| Setting | Value |
| --- | --- |
| Launch kind | `evm_contracts` |
| Network | Sepolia, chain ID 11155111 |
| Owner reference | `$owner`, resolving to `0xa9cec403edbfd2dfe214258c3c0755b79e60aeac` for this assignment |
| Read-only SqueekCore | `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` |
| Solidity | 0.8.26, optimizer 200, Cancun |
| Bytecode metadata hash | none |
| Deployment value | 0 for every constructor |
| Mock token metadata | SQI / SQI; 18 decimals |
| Initial mock supply | 100000000 × 10^18 atoms to `$owner` |

Deploy in this exact order. References point only to earlier applications:

| Order | Contract | Constructor arguments in declaration order |
| --- | --- | --- |
| 1 | `MockSQK` | `$owner` |
| 2 | `PremiumModel` | `$owner` |
| 3 | `CoverPool` | `$owner`, `$contract:MockSQK` |
| 4 | `CoreReader` | `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` |
| 5 | `PolicyBook` | `$owner`, `$contract:MockSQK`, `$contract:PremiumModel`, `$contract:CoverPool`, `$contract:CoreReader` |

All constructors are nonpayable, take static address words, and make no external calls or code-existence checks. They work in an empty-chain constructor rehearsal. Contracts enforce Sepolia chain ID at deployment. Owner arguments are explicit because the launch factory is the constructor caller. Nothing uses `tx.origin` for authorization. Libraries used by applications are inlined; no link placeholders are needed.

## Before activating

The deployer/reviewer rebuilds from the pinned sources, runs the documented tests and checks formatting. Confirm every application's runtime is below EIP-170 and that the manifest lists only these five applications. Test fixtures and `ApplicationFactoryHarness` are never launch entries.

Verify the public Core dependency at a single recent Sepolia block: deployed code is present, `implementationCodeVersion()` is 3, `configuration()` reports genesis, 600-second rounds and a 16-record limit, and `state()` plus `roundPage()` decode using the pinned ABI. Check the live implementation code identity, governance and configuration against the [official deployment record](https://docs.squeekchain.com/developers/#deployments). The application pins the proxy address and compatible version, but does not pin an implementation hash. The source includes historical read evidence, not a current health attestation.

After the deployment service reports the five confirmed addresses, compare every immutable dependency getter against that graph. Confirm ownership of `MockSQK`, `PremiumModel`, `CoverPool` and `PolicyBook` is `$owner`, and the initial supply belongs to that owner. `CoreReader` has no owner or mutable configuration.

## Owner activation

The owner performs these calls manually through their normal wallet workflow after reviewing the confirmed deployment addresses. These are operational actions, not constructor initialization by the factory.

1. Call `CoverPool.setPolicyBook(confirmedPolicyBookAddress)`. It may be called once and checks that the book names this pool and collateral token. Read `policyBook()` back. This is necessary because the required deployment order places the pool before the book. An incorrect binding cannot be repaired through an upgrade.
2. Call `PremiumModel.setRate(N, T, baseBps, slopeBps)` for each desired product. To enable the full requested set, configure all twelve rows below. The owner supplies the prices from their chosen testnet pricing policy; deployment does not insert guessed rates.
3. Read all rows back with `rates(N, T)`. Require `configured = true`, `baseBps > 0`, and `baseBps + slopeBps <= 10000`.
4. Distribute mock tokens to test LPs/buyers. Approve the exact desired LP deposit to `CoverPool`, then call `deposit(amount, minimumShares)`. No initial pool capital is minted or deposited automatically. If more collateral is needed, only the owner can call `MockSQK.mint`.
5. Obtain a fresh quote from `PolicyBook.quote(startRound, N, T, C)`, using a start beyond both clock and frontier. Confirm both pause flags are false. Approve the exact premium to `PolicyBook`, then call `openPolicy(startRound, N, T, C, maxPremium, deadline)` with the buyer's chosen bounds.
6. Verify `PolicyOpened`, the stored policy and `CoverPool.reservations(policyId)`. Confirm `reserved <= totalAssets` and token custody matches accounted assets plus any unsolicited transfers.

| N | T entries, in basis points |
| --- | --- |
| 6 | 3000, 5000, 7000 |
| 12 | 3000, 5000, 7000 |
| 24 | 3000, 5000, 7000 |
| 144 | 3000, 5000, 7000 |

The test suite uses 500 base basis points and a 1000 basis-point utilization slope as test vectors only. They are not deployed defaults or recommended launch prices. Unconfigured products fail with `RateNotConfigured` and cannot take premiums.

## Ongoing responsibilities

- **Owner:** review new-policy prices, monitor Core version/configuration and history availability, maintain control of the faucet and opening pause, and use two-step ownership transfers if needed. `setPaused(true)` stops purchases; it cannot sweep funds, rewrite policies or stop certified settlement.
- **LPs:** use share/asset previews and meaningful minimum outputs; evaluate correlated losses and indefinite reservation risk. Redeem only free liquidity. Send assets through `deposit`, since direct transfers receive no shares and cannot be rescued.
- **Buyers or other callers:** inspect the certified frontier and call `settle(policyId)` when it reaches the inclusive end round. Settlement is one policy per call, permissionless and retryable after transaction failure. There is no requirement to run a keeper, and no reward is paid to the caller.
- **Independent reviewer/deployer:** complete adversarial review, verify deployed source/runtime and run a small live Sepolia smoke cycle with mock funds. Actual token collection, redemption and settlement should be checked against the emitted events and stored policy/reserve values.

If Core stalls, leave unresolved reservations in place and communicate the liveness issue. If Core changes incompatibly, pause new purchases and investigate. This design has no migration, oracle replacement, forced refund or upgrade path; do not promise that an operator can recover unresolved cover through administrative action.

## Validation record

See `test/` for the reproducible offline checks and `THREATS.md` for what they establish and what they do not. The configured fuzz seed is supplied at invocation, not read by Solidity tests. No chain fork, environment variable, local service or external runtime is required by those tests. Deployment/activation has not been broadcast by this assignment.
