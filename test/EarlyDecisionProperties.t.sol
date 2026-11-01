// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoverPool} from "src/CoverPool.sol";
import {PolicyBook} from "src/PolicyBook.sol";

/// @notice Early settlement and review are only sound if a decision taken on a certified prefix is the
/// one every possible completion of the window would give. These properties check that against the
/// brief's rule (pay iff zeroRounds / N >= T) evaluated on the best and the worst completion.
/// forge-config: default.fuzz.runs = 1000
contract EarlyDecisionPropertiesTest is CoverFixture {
    uint16[4] internal durations = [uint16(6), 12, 24, 144];
    uint16[3] internal thresholds = [uint16(3000), 5000, 7000];

    function _pays(uint256 zeros, uint16 n, uint16 t) internal pure returns (bool) {
        return zeros * 10_000 >= uint256(n) * t;
    }

    /// @dev Records the active rounds of `mask` (bit i = round START + i active) for the whole window.
    function _record(uint16 n, uint256 mask) internal {
        for (uint64 i; i < n; ++i) {
            if (((mask >> i) & 1) == 1) core.record(START + i, 1);
        }
    }

    function _prefixZeros(uint256 mask, uint256 certified) internal pure returns (uint256 zeros) {
        for (uint256 i; i < certified; ++i) {
            if (((mask >> i) & 1) == 0) ++zeros;
        }
    }

    function testFuzz_prefixDecisionAgreesWithEveryCompletion(
        uint8 nSeed,
        uint8 tSeed,
        uint256 mask,
        uint16 certifiedSeed,
        bool viaReview
    ) public {
        uint16 n = durations[nSeed % 4];
        uint16 t = thresholds[tSeed % 3];
        uint256 certified = bound(certifiedSeed, 0, n);
        (uint256 id,) = _open(alice, n, t, 100 ether);
        _record(n, mask);
        if (certified != 0) _certify(START + uint64(certified) - 1);

        uint256 zeros = _prefixZeros(mask, certified);
        bool best = _pays(zeros + (n - certified), n, t);
        bool worst = _pays(zeros, n, t);
        uint256 before = token.balanceOf(alice);
        PolicyBook.Policy memory p = book.getPolicy(id);

        if (best != worst) {
            // Some completion pays and some does not: nothing may be decided yet.
            if (viaReview) {
                (bool settled, uint64 decideRound) = book.review(id);
                assertFalse(settled);
                // The earliest round the remaining zeros could first be certified, and never earlier.
                uint64 last = START + uint64(certified) - 1;
                uint256 k = 1;
                while (!_pays(zeros + k, n, t)) ++k;
                assertEq(decideRound, last + k);
                assertLe(decideRound, p.endRound);
                assertFalse(book.settlementPending(), "a reviewed undecided policy must not hold the gate");
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        PolicyBook.Undecided.selector, id, uint16(zeros), uint16(certified)
                    )
                );
                book.settle(id);
            }
            assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.Open));
            assertEq(pool.reserved(), 100 ether);
            assertEq(token.balanceOf(alice), before);
            return;
        }

        // Every completion agrees, so the prefix decides, and it must decide the agreed outcome.
        if (worst) assertTrue(book.settlementPending(), "a fixed payout must close the LP gate");
        uint256 paid;
        if (viaReview) {
            (bool settled,) = book.review(id);
            assertTrue(settled);
            paid = token.balanceOf(alice) - before;
        } else {
            paid = book.settle(id);
        }
        assertEq(paid, worst ? 100 ether : 0);
        assertEq(token.balanceOf(alice), before + paid);
        PolicyBook.Policy memory done = book.getPolicy(id);
        assertEq(uint8(done.status), uint8(worst ? PolicyBook.Status.Paid : PolicyBook.Status.Expired));
        assertEq(done.zeroRounds, zeros, "recorded zero rounds are those of the certified prefix");
        assertEq(pool.reserved(), 0);
        assertFalse(book.settlementPending());
        // Further certification cannot reopen or replay a decided policy.
        _certify(START + n + 10);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.settle(id);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.review(id);
    }

    /// The opening decide round is the first round at which the required zero rounds could all be certified.
    function testFuzz_openingDecideRoundIsTheFirstRoundThatCouldPay(uint8 nSeed, uint8 tSeed) public {
        uint16 n = durations[nSeed % 4];
        uint16 t = thresholds[tSeed % 3];
        (uint256 id,) = _open(alice, n, t, 1 ether);
        uint256 k = 1;
        while (!_pays(k, n, t)) ++k;
        assertEq(book.getPolicy(id).decideRound, START + k - 1);
        assertEq(book.earliestDecideRound(), START + k - 1);
        // One round earlier nothing can have paid yet, so LPs stay free.
        if (k > 1) {
            _certify(START + uint64(k) - 2);
            assertFalse(book.settlementPending());
        }
        _certify(START + uint64(k) - 1);
        assertTrue(book.settlementPending());
        assertEq(book.settle(id), 1 ether, "no records: every certified round is zero-work");
    }

    /// Pinned table of the thresholds at each duration: the smallest paying count of zero rounds.
    function test_requiredZeroRoundsTable() public {
        uint256[3][4] memory expected =
            [[uint256(2), 3, 5], [uint256(4), 6, 9], [uint256(8), 12, 17], [uint256(44), 72, 101]];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 3; ++j) {
                (uint256 id,) = _open(alice, durations[i], thresholds[j], 1 ether);
                assertEq(book.getPolicy(id).decideRound, START + expected[i][j] - 1);
            }
        }
    }

    /// Repeated reviews of a 144-round policy over fully active history: each review moves the decide
    /// round forward, the gate reopens each time, and the policy expires once 50% becomes unreachable.
    function test_reviewChainOnActiveHistoryEndsInEarlyExpiry() public {
        (uint256 id,) = _open(alice, 144, 5000, 10 ether);
        for (uint64 i; i < 144; ++i) {
            core.record(START + i, 1);
        }
        uint64 decide = book.getPolicy(id).decideRound;
        assertEq(decide, START + 71);
        _certify(decide);
        assertTrue(book.settlementPending());
        (bool settled, uint64 next) = book.review(id);
        assertFalse(settled);
        assertEq(next, START + 143, "72 active rounds: all 72 remaining rounds must be zero");
        assertFalse(book.settlementPending());
        uint256 shares = pool.sharesOf(lp) / 10;
        vm.prank(lp);
        assertGt(pool.redeem(shares, 1), 0);
        _certify(START + 72);
        // 73 active of 144: 50% is now unreachable, so the reserve is released before the end.
        assertEq(book.settle(id), 0);
        assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.Expired));
        assertEq(pool.reserved(), 0);
    }

    /// An expiry fixed by the prefix does not close the gate (the decide round tracks payouts only), which
    /// is safe only because expiry does not move the share price: premium was booked at opening and
    /// expiry merely frees the reserve. This pins that reasoning.
    function test_earlyFixedExpiryLeavesGateOpenAndSharePriceUnchanged() public {
        (uint256 id,) = _open(alice, 6, 7000, 100 ether);
        core.record(START, 1);
        core.record(START + 1, 1);
        _certify(START + 1);
        assertEq(book.getPolicy(id).decideRound, START + 4);
        assertFalse(book.settlementPending(), "expiry already fixed, yet the gate is open");
        uint256 priceBefore = pool.previewRedeem(1e18);
        uint256 assetsBefore = pool.totalAssets();
        assertEq(book.settle(id), 0);
        assertEq(pool.previewRedeem(1e18), priceBefore, "expiry must not reprice shares");
        assertEq(pool.totalAssets(), assetsBefore);
        assertEq(pool.freeAssets(), assetsBefore);
    }

    /// A review that changes nothing (frontier still behind the decide round) is a harmless no-op.
    function test_reviewBeforeAnyCertificationKeepsTheDecideRound() public {
        (uint256 id,) = _open(alice, 24, 7000, 10 ether);
        uint64 decide = book.getPolicy(id).decideRound;
        (bool settled, uint64 next) = book.review(id);
        assertFalse(settled);
        assertEq(next, decide);
        assertEq(book.earliestDecideRound(), decide);
        assertEq(book.openPolicyIdsDecidingAt(decide).length, 1);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.review(999);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.review(0);
    }

    /// Review is rejected exactly like settle when the core cannot be read, and moves nothing.
    function test_reviewFailsClosedOnUnreadableHistory() public {
        (uint256 id,) = _open(alice, 6, 5000, 10 ether);
        _certify(START + 2);
        core.setHistoryUnavailable(true);
        vm.expectRevert();
        book.review(id);
        assertEq(book.getPolicy(id).decideRound, START + 2);
        assertEq(pool.reserved(), 10 ether);
        // The gate fails open, as documented, rather than freezing free liquidity.
        assertFalse(book.settlementPending());
        core.setHistoryUnavailable(false);
        assertTrue(book.settlementPending());
        vm.expectRevert(CoverPool.SettlementPending.selector);
        vm.prank(lp);
        pool.redeem(1 ether, 1);
    }
}
