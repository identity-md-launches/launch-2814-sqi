// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {CoverTerms} from "../src/CoverTerms.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract PolicyBookTest is CoverFixture {
    function test_openCollectsPremiumAndReservesEntireCover() public {
        uint256 before = token.balanceOf(alice);
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        PolicyBook.Policy memory p = book.getPolicy(id);
        assertEq(id, 1);
        assertEq(p.holder, alice);
        assertEq(p.startRound, START);
        assertEq(p.endRound, START + 5);
        assertEq(p.rounds, 6);
        assertEq(p.thresholdBps, 5000);
        assertEq(p.cover, 100 ether);
        assertEq(p.premium, 6 ether);
        assertEq(p.premium, premium);
        assertEq(uint8(p.status), uint8(PolicyBook.Status.Open));
        assertEq(token.balanceOf(alice), before - premium);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.allowance(address(book), address(pool)), 0);
        assertEq(pool.reserved(), p.cover);
        assertEq(pool.totalAssets(), 1000 ether + premium);
        (address beneficiary, uint256 cover) = pool.reservations(id);
        assertEq(beneficiary, alice);
        assertEq(cover, p.cover);
        _assertSolvent();
    }

    function test_anyoneSettlesAndOnlyHolderReceivesPayout() public {
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        core.record(START, 100);
        core.record(START + 2, 2);
        core.record(START + 4, 1);
        _certify(START + 5);
        uint256 before = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        assertEq(book.settle(id), 100 ether);
        assertEq(token.balanceOf(alice), before + 100 ether);
        assertEq(token.balanceOf(bob), bobBefore);
        PolicyBook.Policy memory p = book.getPolicy(id);
        assertEq(p.zeroRounds, 3);
        assertEq(uint8(p.status), uint8(PolicyBook.Status.Paid));
        assertEq(pool.totalAssets(), 1000 ether + premium - 100 ether);
        assertEq(pool.reserved(), 0);
        _assertSolvent();
    }

    function test_nonTriggerRetainsPremiumAndReleasesReserve() public {
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        for (uint64 r = START; r < START + 4; ++r) {
            core.record(r, 1);
        }
        _certify(START + 5);
        uint256 before = token.balanceOf(alice);
        assertEq(book.settle(id), 0);
        assertEq(token.balanceOf(alice), before);
        assertEq(pool.totalAssets(), 1000 ether + premium);
        assertEq(pool.reserved(), 0);
        assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.Expired));
        assertEq(book.getPolicy(id).zeroRounds, 2);
    }

    function test_unknownRoundsNeverSettleEvenYearsLater() public {
        (uint256 id,) = _open(alice, 6, 3000, 100 ether);
        core.setFrontier(START + 4);
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.UnknownRounds.selector, START + 5, START + 4));
        book.settle(id);
        assertEq(pool.reserved(), 100 ether);
        assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.Open));
        core.setFrontier(START + 5);
        assertEq(book.settle(id), 100 ether);
    }

    function test_settlesAtFrontierEqualEnd() public {
        (uint256 id,) = _open(alice, 6, 7000, 100 ether);
        _certify(START + 5);
        assertEq(book.settle(id), 100 ether);
    }

    function test_settlementCannotReplayOrSettleMissingId() public {
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.settle(0);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.settle(1);
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        _certify(START + 5);
        book.settle(id);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        book.settle(id);
    }

    function test_pauseBlocksOpenButAllowsCertifiedSettlement() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        vm.prank(owner);
        book.setPaused(true);
        vm.expectRevert(PolicyBook.OpeningPaused.selector);
        book.openPolicy(START, 6, 5000, 1 ether, 1 ether, block.timestamp);
        _certify(START + 5);
        core.setPaused(true);
        assertEq(book.settle(id), 100 ether);
        vm.prank(owner);
        book.setPaused(false);
        vm.expectRevert(PolicyBook.CorePaused.selector);
        book.openPolicy(START + 6, 6, 5000, 1 ether, 1 ether, block.timestamp);
    }

    function test_corePauseBlocksOpenWithoutAppPause() public {
        core.setPaused(true);
        vm.expectRevert(PolicyBook.CorePaused.selector);
        book.quote(START, 6, 5000, 100 ether);
    }

    function test_startMustExceedClockEvenWhenCoreIsBehind() public {
        for (uint64 start = 99; start <= 101; ++start) {
            vm.expectRevert(
                abi.encodeWithSelector(PolicyBook.StartNotFuture.selector, start, uint64(100), uint64(101))
            );
            book.openPolicy(start, 6, 5000, 1 ether, 1 ether, block.timestamp);
        }
        vm.warp(GENESIS + 999 * 600);
        vm.expectRevert(
            abi.encodeWithSelector(PolicyBook.StartNotFuture.selector, uint64(101), uint64(100), uint64(1000))
        );
        book.quote(101, 6, 5000, 1 ether);
        book.quote(1001, 6, 5000, 1 ether);
    }

    function test_rejectsInvalidTermsAndOverflow() public {
        vm.expectRevert(CoverTerms.InvalidDuration.selector);
        book.quote(START, 5, 5000, 1 ether);
        vm.expectRevert(CoverTerms.InvalidThreshold.selector);
        book.quote(START, 6, 50, 1 ether);
        vm.expectRevert(CoverTerms.InvalidStartRound.selector);
        book.quote(0, 6, 5000, 1 ether);
        vm.expectRevert(CoverTerms.RoundOverflow.selector);
        book.quote(type(uint64).max, 6, 5000, 1 ether);
        vm.expectRevert(PremiumModel.InvalidCover.selector);
        book.quote(START, 6, 5000, 0);
    }

    function test_frontRunPriceIncreaseRespectsMaxPremium() public {
        (uint256 quoted,) = book.quote(START, 6, 5000, 100 ether);
        _open(bob, 6, 5000, 500 ether);
        (uint256 nowQuoted,) = book.quote(START, 6, 5000, 100 ether);
        assertGt(nowQuoted, quoted);
        vm.expectRevert(abi.encodeWithSelector(PolicyBook.PremiumExceeded.selector, nowQuoted, quoted));
        vm.prank(alice);
        book.openPolicy(START, 6, 5000, 100 ether, quoted, block.timestamp);
        assertEq(book.nextPolicyId(), 2);
    }

    function test_expiredDeadlineAndBoundary() public {
        vm.expectRevert(PolicyBook.DeadlineExpired.selector);
        book.openPolicy(START, 6, 5000, 100 ether, 100 ether, block.timestamp - 1);
        _open(alice, 6, 5000, 100 ether); // deadline == timestamp succeeds
    }

    function test_unpaidPremiumRollsBackPolicyAndReservation() public {
        (uint256 premium,) = book.quote(START, 6, 5000, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, premium
            )
        );
        vm.prank(alice);
        book.openPolicy(START, 6, 5000, 100 ether, premium, block.timestamp);
        assertEq(book.nextPolicyId(), 1);
        assertEq(pool.reserved(), 0);
        assertEq(pool.totalAssets(), 1000 ether);
    }

    function test_noCoverCanDependOnItsOwnIncomingPremium() public {
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        book.quote(START, 6, 5000, 1000 ether + 1);
        _open(alice, 6, 5000, 1000 ether);
        _assertSolvent();
    }

    function test_overlappingPoliciesSettleIndependentlyInReverseOrder() public {
        (uint256 first, uint256 firstPremium) = _open(alice, 6, 5000, 400 ether);
        (uint256 second, uint256 secondPremium) = _open(bob, 12, 7000, 500 ether);
        assertEq(pool.reserved(), 900 ether);
        _certify(START + 11);
        book.settle(second);
        assertEq(pool.reserved(), 400 ether);
        _assertSolvent();
        book.settle(first);
        assertEq(pool.reserved(), 0);
        assertEq(pool.totalAssets(), 100 ether + firstPremium + secondPremium);
        _assertSolvent();
    }

    function test_rateUpdatesDoNotChangePurchasedPolicy() public {
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        vm.prank(owner);
        model.setRate(6, 5000, 9000, 1000);
        assertEq(book.getPolicy(id).premium, premium);
        _certify(START + 5);
        assertEq(book.settle(id), 100 ether);
    }

    function testFuzz_allTermsExactThreshold(
        uint8 durationIndex,
        uint8 thresholdIndex,
        uint8 zeroSeed,
        uint96 coverSeed
    ) public {
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        uint16 n = durations[durationIndex % 4];
        uint16 t = thresholds[thresholdIndex % 3];
        uint16 zeros = uint16(bound(zeroSeed, 0, n));
        uint256 cover = bound(coverSeed, 1, 1000 ether);
        (uint256 id, uint256 premium) = _open(alice, n, t, cover);
        // Sparse gaps at the front and trailing zeros both count, including zero-work-only pages.
        for (uint64 i = zeros; i < n; ++i) {
            core.record(START + i, 1);
        }
        _certify(START + n - 1);
        uint256 minimumZeros = (uint256(n) * t + 9999) / 10_000;
        uint256 expected = zeros >= minimumZeros ? cover : 0;
        uint256 before = token.balanceOf(alice);
        assertEq(book.settle(id), expected);
        assertEq(book.getPolicy(id).zeroRounds, zeros);
        assertEq(token.balanceOf(alice), before + expected);
        assertEq(pool.totalAssets(), 1000 ether + premium - expected);
        _assertSolvent();
    }
}
