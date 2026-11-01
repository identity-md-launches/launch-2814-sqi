// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoverFixture} from "./helpers/CoverFixture.sol";
import {OpenEndRoundsHarness} from "./helpers/OpenEndRoundsHarness.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {CoreReader} from "../src/CoreReader.sol";

/// @notice Nobody deposits or redeems at a share price that certified history has already made stale.
contract SettlementGateTest is CoverFixture {
    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(pool), amount);
        pool.deposit(amount, 1);
        vm.stopPrank();
    }

    function test_certifiedLossIsSharedByEveryLpPresentAtTheSale() public {
        _deposit(bob, 1000 ether);
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 1000 ether);
        assertEq(pool.totalAssets(), 2000 ether + premium);
        assertFalse(book.settlementPending());
        _certify(START + 5);
        assertTrue(book.settlementPending());

        uint256 lpShares = pool.sharesOf(lp);
        vm.prank(lp);
        vm.expectRevert(CoverPool.SettlementPending.selector);
        pool.redeem(lpShares, 1);
        vm.startPrank(lp);
        token.approve(address(pool), 1 ether);
        vm.expectRevert(CoverPool.SettlementPending.selector);
        pool.deposit(1 ether, 1);
        vm.stopPrank();

        uint256[] memory pending = book.openPolicyIdsEndingAt(START + 5);
        assertEq(pending.length, 1);
        assertEq(pending[0], id);
        assertEq(book.settle(id), 1000 ether);
        assertFalse(book.settlementPending());
        assertEq(book.openPolicyIdsEndingAt(START + 5).length, 0);

        uint256 expected = (1000 ether + premium) / 2;
        vm.prank(lp);
        assertApproxEqAbs(pool.redeem(lpShares, 1), expected, 1);
        assertApproxEqAbs(pool.previewRedeem(pool.sharesOf(bob)), expected, 1);
        _assertSolvent();
    }

    function test_gateOpensOnlyWhenTheWholeWindowIsCertified() public {
        (uint256 id,) = _open(alice, 6, 3000, 500 ether);
        _certify(START + 4);
        assertFalse(book.settlementPending());
        vm.prank(lp);
        pool.redeem(1e9, 1);
        _certify(START + 5);
        assertTrue(book.settlementPending());
        vm.prank(lp);
        vm.expectRevert(CoverPool.SettlementPending.selector);
        pool.redeem(1e9, 1);
        assertEq(book.settle(id), 500 ether);
        vm.prank(lp);
        pool.redeem(1e9, 1);
    }

    function test_gateFailsOpenWhenTheCoreCannotBeRead() public {
        _open(alice, 6, 5000, 100 ether);
        _certify(START + 5);
        assertTrue(book.settlementPending());
        core.setUnavailable(true);
        assertFalse(book.settlementPending());
        vm.prank(lp);
        pool.redeem(1e6, 1);
        core.setUnavailable(false);
        core.setVersion(4);
        assertFalse(book.settlementPending());
        vm.expectRevert(CoreReader.UnsupportedCoreVersion.selector);
        book.settle(1);
        vm.prank(lp);
        pool.redeem(1e6, 1);
    }

    function test_earliestOpenEndTracksSettlementInAnyOrder() public {
        assertEq(book.earliestOpenEnd(), 0);
        assertEq(book.openPolicyCount(), 0);
        (uint256 first,) = _open(alice, 6, 5000, 100 ether); // ends 107
        (uint256 second,) = _open(bob, 6, 5000, 100 ether); // ends 107
        assertEq(book.earliestOpenEnd(), START + 5);
        (uint256 premium,) = book.quote(300, 144, 3000, 100 ether);
        vm.startPrank(alice);
        token.approve(address(book), premium);
        uint256 third = book.openPolicy(300, 144, 3000, 100 ether, premium, block.timestamp); // ends 443
        vm.stopPrank();
        (premium,) = book.quote(1000, 6, 5000, 100 ether);
        vm.startPrank(bob);
        token.approve(address(book), premium);
        uint256 fourth = book.openPolicy(1000, 6, 5000, 100 ether, premium, block.timestamp); // ends 1005
        vm.stopPrank();
        assertEq(book.openPolicyCount(), 4);
        assertEq(book.earliestOpenEnd(), START + 5);

        _certify(1005);
        assertTrue(book.settlementPending());
        book.settle(first);
        assertEq(book.earliestOpenEnd(), START + 5);
        book.settle(fourth);
        assertEq(book.earliestOpenEnd(), START + 5);
        book.settle(second);
        assertEq(book.earliestOpenEnd(), 443);
        assertTrue(book.settlementPending());
        book.settle(third);
        assertEq(book.earliestOpenEnd(), 0);
        assertEq(book.openPolicyCount(), 0);
        assertFalse(book.settlementPending());
    }

    function test_startRoundLeadIsCapped() public {
        (, uint64 current,) = reader.snapshot();
        uint64 latest = current + book.MAX_LEAD_ROUNDS();
        book.quote(latest, 6, 5000, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PolicyBook.StartTooFar.selector, latest + 1, latest));
        book.quote(latest + 1, 6, 5000, 1 ether);
        uint64 far = type(uint64).max - 143;
        vm.expectRevert(abi.encodeWithSelector(PolicyBook.StartTooFar.selector, far, latest));
        book.openPolicy(far, 144, 3000, 1000 ether, type(uint256).max, block.timestamp);
        assertEq(pool.reserved(), 0);
        // The cap follows the wall clock, not the possibly stalled frontier.
        vm.warp(GENESIS + 5000 * 600);
        (, current,) = reader.snapshot();
        assertEq(current, 5001);
        latest = current + book.MAX_LEAD_ROUNDS();
        book.quote(latest, 6, 5000, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PolicyBook.StartTooFar.selector, latest + 1, latest));
        book.quote(latest + 1, 6, 5000, 1 ether);
    }

    function test_settlementSurvivesRaisedOrLoweredCoreBatchLimit() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        _certify(START + 5);
        core.setBatchLimit(32);
        vm.expectCall(address(core), abi.encodeCall(core.roundPage, (START - 1, START + 5, 16)));
        assertEq(book.settle(id), 100 ether);
        book.quote(START + 10, 6, 5000, 1 ether);

        (, uint64 current,) = reader.snapshot();
        uint64 start = current + 1;
        for (uint64 r = start; r < start + 24; ++r) {
            core.record(r, 1);
        }
        (uint256 premium,) = book.quote(start, 24, 7000, 100 ether);
        vm.startPrank(bob);
        token.approve(address(book), premium);
        id = book.openPolicy(start, 24, 7000, 100 ether, premium, block.timestamp);
        vm.stopPrank();
        core.setBatchLimit(4);
        _certify(start + 23);
        assertEq(reader.countZeroRounds(start, 24), 0);
        for (uint64 cursor = start - 1; cursor < start + 23; cursor += 4) {
            vm.expectCall(address(core), abi.encodeCall(core.roundPage, (cursor, start + 23, 4)));
        }
        assertEq(book.settle(id), 0);
        core.setBatchLimit(0);
        vm.expectRevert(CoreReader.InvalidConfiguration.selector);
        reader.snapshot();
    }
}

contract OpenEndRoundsTest is Test {
    OpenEndRoundsHarness internal set;

    function setUp() public {
        set = new OpenEndRoundsHarness();
    }

    function test_spansWordsAndSummaryWordsAndEmptiesCleanly() public {
        set.add(70_000);
        set.add(5);
        set.add(5);
        set.add(300);
        assertEq(set.earliest(), 5);
        set.remove(5);
        assertEq(set.earliest(), 5);
        set.remove(5);
        assertEq(set.earliest(), 300);
        set.remove(300);
        assertEq(set.earliest(), 70_000);
        // Ten years of rounds apart: the summary skips the empty words in between.
        set.add(70_000 + 525_600);
        set.remove(70_000);
        assertEq(set.earliest(), 70_000 + 525_600);
        set.remove(70_000 + 525_600);
        assertEq(set.earliest(), 0);
        assertEq(set.count(), 0);
        // A larger end never displaces a smaller earliest; a smaller one always does.
        set.add(1000);
        set.add(2000);
        assertEq(set.earliest(), 1000);
        set.add(999);
        assertEq(set.earliest(), 999);
    }

    function testFuzz_earliestMatchesNaiveMinimum(uint64[8] memory ends, uint8 removalMask) public {
        for (uint256 i; i < 8; ++i) {
            ends[i] = uint64(bound(ends[i], 1, 200_000));
            set.add(ends[i]);
        }
        bool[8] memory removed;
        for (uint256 i; i < 8; ++i) {
            if ((removalMask >> i) & 1 == 1) {
                set.remove(ends[i]);
                removed[i] = true;
            }
        }
        uint64 expected;
        uint256 expectedCount;
        for (uint256 i; i < 8; ++i) {
            if (removed[i]) continue;
            ++expectedCount;
            if (expected == 0 || ends[i] < expected) expected = ends[i];
        }
        assertEq(set.earliest(), expected);
        assertEq(set.count(), expectedCount);
    }
}
