// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoverFixture} from "./helpers/CoverFixture.sol";
import {MockCore} from "./helpers/MockCore.sol";
import {MockSQK} from "../src/MockSQK.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoverHandler is Test {
    MockSQK public immutable token;
    CoverPool public immutable pool;
    PolicyBook public immutable book;
    CoreReader public immutable reader;
    MockCore public immutable core;
    address public immutable owner;
    address[3] public actors;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public premiums;
    uint256 public payouts;
    uint256 public donations;
    uint256 public opened;
    uint256 public roundTrips;
    uint256 public rejectedSettlements;
    uint256 public pendingRejections;
    mapping(uint64 round => bool active) public activeRounds;
    mapping(uint256 => bytes32) public policyTerms;
    mapping(uint256 => PolicyBook.Status) public policyStatus;
    mapping(uint256 => uint16) public policyZeros;

    constructor(
        MockSQK token_,
        CoverPool pool_,
        PolicyBook book_,
        address owner_,
        address[3] memory actors_
    ) {
        token = token_;
        pool = pool_;
        book = book_;
        reader = book_.reader();
        core = MockCore(address(reader.core()));
        owner = owner_;
        actors = actors_;
    }

    function deposit(uint8 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        if (book.settlementPending()) return;
        uint256 shares = pool.previewDeposit(amount);
        if (shares == 0) return;
        vm.startPrank(actor);
        token.approve(address(pool), amount);
        pool.deposit(amount, shares);
        vm.stopPrank();
        deposits += amount;
    }

    function redeem(uint8 actorSeed, uint256 shareSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 maximum = Math.mulDiv(
            pool.freeAssets(), pool.totalShares() + pool.VIRTUAL_SHARES(), pool.totalAssets() + 1
        );
        maximum = Math.min(maximum, pool.sharesOf(actor));
        if (maximum == 0 || book.settlementPending()) return;
        uint256 shares = bound(shareSeed, 1, maximum);
        uint256 assets = pool.previewRedeem(shares);
        if (assets == 0) return;
        vm.prank(actor);
        withdrawals += pool.redeem(shares, assets);
    }

    function open(uint8 actorSeed, uint96 coverSeed, uint8 durationSeed, uint8 thresholdSeed) external {
        if (book.paused() || core.paused()) return;
        address actor = actors[actorSeed % 3];
        uint256 maximum = Math.min(pool.freeAssets(), token.balanceOf(actor));
        if (maximum == 0) return;
        uint256 cover = bound(coverSeed, 1, maximum);
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        uint16 n = durations[durationSeed % 4];
        uint16 t = thresholds[thresholdSeed % 3];
        (, uint64 current,) = reader.snapshot();
        (uint256 premium,) = book.quote(current + 1, n, t, cover);
        vm.startPrank(actor);
        token.approve(address(book), premium);
        uint256 id = book.openPolicy(current + 1, n, t, cover, premium, block.timestamp);
        vm.stopPrank();
        assertEq(id, ++opened, "successful opens alone allocate IDs");
        policyTerms[id] = keccak256(abi.encode(actor, current + 1, current + n, n, t, cover, premium));
        policyStatus[id] = PolicyBook.Status.Open;
        premiums += premium;
    }

    function advance(uint8 roundsSeed, uint256 mask) external {
        uint64 old = core.frontier();
        uint64 end = old + uint64(bound(roundsSeed, 1, 144));
        for (uint64 r = old + 1; r <= end; ++r) {
            if (((mask >> (r - old - 1)) & 1) == 1) {
                activeRounds[r] = true;
                core.record(r, 1);
            }
        }
        core.setFrontier(end);
        uint256 endTime = uint256(core.genesis()) + uint256(end) * 600;
        if (endTime > block.timestamp) vm.warp(endTime);
    }

    function settle(uint96 idSeed, uint8 actorSeed) external {
        uint256 count = book.nextPolicyId() - 1;
        if (count == 0) return;
        uint256 id = bound(idSeed, 1, count);
        PolicyBook.Policy memory policy = book.getPolicy(id);
        if (policy.status != PolicyBook.Status.Open || policy.endRound > core.frontier()) return;
        assertTrue(book.settlementPending());
        assertLe(book.earliestOpenEnd(), policy.endRound);
        uint256 zeros;
        for (uint64 r = policy.startRound; r <= policy.endRound; ++r) {
            if (!activeRounds[r]) ++zeros;
        }
        uint256 expected = zeros * 10_000 >= uint256(policy.rounds) * policy.thresholdBps ? policy.cover : 0;
        uint256 before = token.balanceOf(policy.holder);
        vm.prank(actors[actorSeed % 3]);
        uint256 paid = book.settle(id);
        assertEq(paid, expected);
        assertEq(token.balanceOf(policy.holder), before + expected);
        policyZeros[id] = uint16(zeros);
        policyStatus[id] = expected == 0 ? PolicyBook.Status.Expired : PolicyBook.Status.Paid;
        payouts += paid;
    }

    /// @dev Multiple immediate cycles at the current share price, including after premiums and losses.
    function roundTrip(uint8 actorSeed, uint96 amountSeed, uint8 cyclesSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 cycles = bound(cyclesSeed, 1, 8);
        uint256 originalBalance = token.balanceOf(actor);
        uint256 originalAssets = pool.totalAssets();
        uint256 originalReserved = pool.reserved();
        if (book.settlementPending()) {
            // A certified but unsettled policy makes the share price stale: both LP paths must refuse.
            uint256 amount = bound(amountSeed, 1, Math.max(originalBalance, 1));
            vm.startPrank(actor);
            token.approve(address(pool), amount);
            vm.expectRevert(CoverPool.SettlementPending.selector);
            pool.deposit(amount, 1);
            uint256 held = pool.sharesOf(actor);
            if (held != 0) {
                vm.expectRevert(CoverPool.SettlementPending.selector);
                pool.redeem(held, 1);
            }
            vm.stopPrank();
            ++pendingRejections;
            return;
        }
        for (uint256 i; i < cycles; ++i) {
            uint256 balance = token.balanceOf(actor);
            if (balance == 0) break;
            uint256 amount = bound(amountSeed, 1, Math.min(balance, 100 ether));
            uint256 quotedShares = pool.previewDeposit(amount);
            if (quotedShares == 0) break;
            uint256 originalShares = pool.sharesOf(actor);
            vm.startPrank(actor);
            token.approve(address(pool), amount);
            uint256 shares = pool.deposit(amount, quotedShares);
            deposits += amount;
            assertEq(shares, quotedShares);
            assertEq(pool.sharesOf(actor), originalShares + shares);
            uint256 quotedAssets = pool.previewRedeem(shares);
            assertLe(quotedAssets, amount, "immediate cycle creates no assets");
            if (quotedAssets == 0) {
                vm.expectRevert(CoverPool.Slippage.selector);
                pool.redeem(shares, 1);
                vm.stopPrank();
                break;
            }
            uint256 returned = pool.redeem(shares, quotedAssets);
            vm.stopPrank();
            assertEq(returned, quotedAssets);
            assertEq(pool.sharesOf(actor), originalShares);
            assertLe(token.balanceOf(actor), balance);
            withdrawals += returned;
            ++roundTrips;
        }
        assertLe(token.balanceOf(actor), originalBalance);
        assertGe(pool.totalAssets(), originalAssets);
        assertEq(pool.reserved(), originalReserved);
    }

    function reprice(uint8 durationSeed, uint8 thresholdSeed, uint16 baseSeed, uint16 slopeSeed) external {
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        uint16 base = uint16(bound(baseSeed, 1, 10_000));
        uint16 slope = uint16(bound(slopeSeed, 0, 10_000 - base));
        PremiumModel model = book.premiumModel();
        vm.prank(owner);
        model.setRate(durations[durationSeed % 4], thresholds[thresholdSeed % 3], base, slope);
    }

    function rejectEarlyOrReplay(uint96 idSeed, uint8 actorSeed) external {
        if (opened == 0) return;
        uint256 id = bound(idSeed, 1, opened);
        PolicyBook.Policy memory policy = book.getPolicy(id);
        bytes memory reason;
        if (policy.status != PolicyBook.Status.Open) {
            reason = abi.encodeWithSelector(PolicyBook.PolicyNotOpen.selector);
        } else if (policy.endRound > core.frontier()) {
            reason =
                abi.encodeWithSelector(CoreReader.UnknownRounds.selector, policy.endRound, core.frontier());
        } else {
            return;
        }
        uint256 assets = pool.totalAssets();
        uint256 reserved = pool.reserved();
        uint256 holderBalance = token.balanceOf(policy.holder);
        vm.expectRevert(reason);
        vm.prank(actors[actorSeed % 3]);
        book.settle(id);
        assertEq(keccak256(abi.encode(book.getPolicy(id))), keccak256(abi.encode(policy)));
        assertEq(pool.totalAssets(), assets);
        assertEq(pool.reserved(), reserved);
        assertEq(token.balanceOf(policy.holder), holderBalance);
        ++rejectedSettlements;
    }

    function transferBetweenActors(uint8 fromSeed, uint8 toSeed, uint96 amountSeed) external {
        address from = actors[fromSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(actors[toSeed % 3], amount);
    }

    function donate(uint8 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(actor);
        token.transfer(address(pool), amount);
        donations += amount;
    }

    function pause(bool appPaused, bool corePaused) external {
        vm.prank(owner);
        book.setPaused(appPaused);
        core.setPaused(corePaused);
    }

    function elapse(uint24 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 12 * 600));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SolvencyInvariantTest is CoverFixture {
    CoverHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CoverHandler(token, pool, book, owner, [lp, alice, bob]);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = CoverHandler.deposit.selector;
        selectors[1] = CoverHandler.redeem.selector;
        selectors[2] = CoverHandler.open.selector;
        selectors[3] = CoverHandler.advance.selector;
        selectors[4] = CoverHandler.settle.selector;
        selectors[5] = CoverHandler.donate.selector;
        selectors[6] = CoverHandler.pause.selector;
        selectors[7] = CoverHandler.elapse.selector;
        selectors[8] = CoverHandler.roundTrip.selector;
        selectors[9] = CoverHandler.reprice.selector;
        selectors[10] = CoverHandler.rejectEarlyOrReplay.selector;
        selectors[11] = CoverHandler.transferBetweenActors.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allObligationsRemainFullyBacked() public view {
        uint256 obligations;
        uint256 openCount;
        uint64 earliest;
        for (uint256 id = 1; id < book.nextPolicyId(); ++id) {
            PolicyBook.Policy memory p = book.getPolicy(id);
            (address beneficiary, uint256 reservedCover) = pool.reservations(id);
            if (p.status == PolicyBook.Status.Open) {
                ++openCount;
                if (earliest == 0 || p.endRound < earliest) earliest = p.endRound;
                obligations += p.cover;
                assertEq(reservedCover, p.cover);
                assertEq(beneficiary, p.holder);
            } else {
                assertEq(reservedCover, 0);
                assertTrue(p.status == PolicyBook.Status.Paid || p.status == PolicyBook.Status.Expired);
            }
        }
        assertEq(pool.reserved(), obligations);
        assertEq(book.openPolicyCount(), openCount, "open policy count drifted");
        assertEq(book.earliestOpenEnd(), earliest, "earliest open end differs from naive minimum");
        assertEq(
            book.settlementPending(),
            earliest != 0 && earliest <= handler.core().frontier(),
            "LP gate disagrees with certified open policies"
        );
        _assertSolvent();
    }

    function invariant_assetsAreConservedAndSharesReconcile() public view {
        assertLe(pool.totalShares(), type(uint256).max - pool.VIRTUAL_SHARES(), "share denominator overflows");
        assertEq(
            pool.totalAssets() + handler.withdrawals() + handler.payouts(),
            1000 ether + handler.deposits() + handler.premiums()
        );
        assertEq(token.balanceOf(address(pool)), pool.totalAssets() + handler.donations());
        assertEq(pool.totalShares(), pool.sharesOf(lp) + pool.sharesOf(alice) + pool.sharesOf(bob));
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.allowance(address(book), address(pool)), 0);
        assertLe(
            pool.previewRedeem(pool.sharesOf(lp)) + pool.previewRedeem(pool.sharesOf(alice))
                + pool.previewRedeem(pool.sharesOf(bob)),
            pool.totalAssets(),
            "aggregate LP redemption claims exceed NAV"
        );
        assertEq(
            token.balanceOf(owner) + token.balanceOf(lp) + token.balanceOf(alice) + token.balanceOf(bob)
                + token.balanceOf(address(pool)) + token.balanceOf(address(book)),
            token.totalSupply(),
            "cover and LP flows cannot create or lose tokens"
        );
    }

    function invariant_policyTermsAndTerminalStatesMatchPurchaseHistory() public view {
        assertEq(book.nextPolicyId(), handler.opened() + 1);
        uint256 collected;
        uint256 paid;
        for (uint256 id = 1; id <= handler.opened(); ++id) {
            PolicyBook.Policy memory p = book.getPolicy(id);
            assertEq(
                keccak256(
                    abi.encode(
                        p.holder, p.startRound, p.endRound, p.rounds, p.thresholdBps, p.cover, p.premium
                    )
                ),
                handler.policyTerms(id),
                "purchase terms changed"
            );
            assertEq(uint8(p.status), uint8(handler.policyStatus(id)), "policy state differs from history");
            assertEq(p.zeroRounds, handler.policyZeros(id));
            assertTrue(pool.usedPolicyIds(id), "reservation ID lost its replay protection");
            collected += p.premium;
            if (p.status == PolicyBook.Status.Paid) paid += p.cover;
        }
        assertEq(collected, handler.premiums());
        assertEq(paid, handler.payouts());
    }

    function test_handlerExercisesSuccessfulPayoutAndRedemption() public {
        handler.deposit(1, 100 ether);
        handler.open(1, 100 ether, 0, 0);
        handler.advance(7, 0);
        handler.settle(1, 2);
        assertEq(handler.payouts(), 100 ether);
        handler.redeem(0, uint96(10 ether * 1e6));
        assertGt(handler.withdrawals(), 0);
        invariant_allObligationsRemainFullyBacked();
        invariant_assetsAreConservedAndSharesReconcile();
        invariant_policyTermsAndTerminalStatesMatchPurchaseHistory();
    }

    function test_handlerExercisesRoundingRepricingFailureAndExpiryPaths() public {
        handler.open(1, 100 ether, 0, 0);
        handler.rejectEarlyOrReplay(1, 2);
        handler.reprice(0, 0, 10_000, 0);
        handler.roundTrip(2, 1 ether + 1, 8);
        handler.advance(7, type(uint256).max);
        handler.settle(1, 0);
        handler.rejectEarlyOrReplay(1, 2);
        handler.roundTrip(0, 1 ether + 1, 8);
        handler.transferBetweenActors(1, 2, 1 ether);
        assertEq(handler.roundTrips(), 16);
        assertEq(handler.rejectedSettlements(), 2);
        assertEq(uint8(book.getPolicy(1).status), uint8(PolicyBook.Status.Expired));
        invariant_allObligationsRemainFullyBacked();
        invariant_assetsAreConservedAndSharesReconcile();
        invariant_policyTermsAndTerminalStatesMatchPurchaseHistory();
    }

    function test_handlerLpFlowsRefuseStalePriceUntilAnyoneSettles() public {
        handler.roundTrip(0, 1 ether, 1);
        handler.open(1, 100 ether, 0, 0);
        handler.advance(7, 0);
        assertTrue(book.settlementPending());
        handler.roundTrip(0, 1 ether, 4);
        assertEq(handler.pendingRejections(), 1);
        assertEq(handler.roundTrips(), 1);
        handler.settle(1, 2);
        assertFalse(book.settlementPending());
        handler.roundTrip(0, 1 ether, 4);
        assertEq(handler.roundTrips(), 5);
        invariant_allObligationsRemainFullyBacked();
        invariant_assetsAreConservedAndSharesReconcile();
        invariant_policyTermsAndTerminalStatesMatchPurchaseHistory();
    }

    function test_handlerRoundTripsAfterCoveredLossAndWhilePaused() public {
        handler.open(1, 100 ether, 0, 0);
        handler.advance(7, 0);
        handler.settle(1, 2);
        handler.pause(true, true);
        handler.roundTrip(2, 3 ether + 1, 8);
        assertEq(handler.roundTrips(), 8);
        invariant_allObligationsRemainFullyBacked();
        invariant_assetsAreConservedAndSharesReconcile();
        invariant_policyTermsAndTerminalStatesMatchPurchaseHistory();
    }
}
