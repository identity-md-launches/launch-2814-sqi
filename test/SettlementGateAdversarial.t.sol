// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoverPool} from "src/CoverPool.sol";
import {PolicyBook} from "src/PolicyBook.sol";

/// @notice Adversarial inputs against the LP settlement gate added with OpenEndRounds.
contract SettlementGateAdversarialTest is CoverFixture {
    function _lpRedeemReverts(bytes4 selector) internal {
        uint256 shares = pool.sharesOf(lp) / 100;
        vm.expectRevert(selector);
        vm.prank(lp);
        pool.redeem(shares, 1);
    }

    function _bobDepositReverts(bytes4 selector) internal {
        vm.startPrank(bob);
        token.approve(address(pool), 1 ether);
        vm.expectRevert(selector);
        pool.deposit(1 ether, 1);
        vm.stopPrank();
    }

    /// One-atom policies are accepted (premium rounds up to one atom), and every one of them must be
    /// settled before any LP can enter or leave. See the low-severity finding on dust policies.
    function test_dustPoliciesMustEachBeSettledBeforeLpsCanMove() public {
        uint256 count = 20;
        vm.startPrank(bob);
        token.approve(address(book), count);
        for (uint256 i; i < count; ++i) {
            (uint256 premium,) = book.quote(START, 6, 5000, 1);
            assertEq(premium, 1, "one-atom cover costs one atom");
            book.openPolicy(START, 6, 5000, 1, 1, block.timestamp);
        }
        vm.stopPrank();
        assertEq(book.openPolicyCount(), count);
        assertEq(book.openPolicyIdsEndingAt(START + 5).length, count);
        _certify(START + 5);
        assertTrue(book.settlementPending());
        for (uint256 id = 1; id < count; ++id) {
            book.settle(id);
            _lpRedeemReverts(CoverPool.SettlementPending.selector);
        }
        assertEq(book.openPolicyIdsEndingAt(START + 5).length, 1);
        _bobDepositReverts(CoverPool.SettlementPending.selector);
        book.settle(count);
        assertFalse(book.settlementPending());
        assertEq(book.earliestOpenEnd(), 0);
        uint256 slice = pool.sharesOf(lp) / 100;
        vm.prank(lp);
        assertGt(pool.redeem(slice, 1), 0);
    }

    /// The gate follows the earliest open end only: a later uncertified window never blocks LPs.
    function test_gateIgnoresUncertifiedLaterWindowsAndReopensAfterEarliestSettles() public {
        (uint256 shortId,) = _open(alice, 6, 5000, 10 ether);
        (uint256 longId,) = _open(alice, 144, 5000, 10 ether);
        assertEq(book.earliestOpenEnd(), START + 5);
        _certify(START + 4);
        assertFalse(book.settlementPending(), "frontier one short of the earliest end");
        _certify(START + 5);
        assertTrue(book.settlementPending());
        _lpRedeemReverts(CoverPool.SettlementPending.selector);
        vm.expectRevert();
        book.settle(longId);
        vm.prank(bob);
        book.settle(shortId);
        assertEq(book.earliestOpenEnd(), START + 143);
        assertFalse(book.settlementPending());
        uint256 slice = pool.sharesOf(lp) / 100;
        vm.prank(lp);
        assertGt(pool.redeem(slice, 1), 0);
        assertEq(uint8(book.getPolicy(longId).status), uint8(PolicyBook.Status.Open));
    }

    /// Neither pause hides certified history: the gate stays closed and settlement still opens it.
    function test_pausesDoNotHideAPendingSettlement() public {
        (uint256 id,) = _open(alice, 6, 3000, 10 ether);
        _certify(START + 5);
        vm.prank(owner);
        book.setPaused(true);
        core.setPaused(true);
        assertTrue(book.settlementPending());
        _bobDepositReverts(CoverPool.SettlementPending.selector);
        _lpRedeemReverts(CoverPool.SettlementPending.selector);
        assertEq(book.settle(id), 10 ether, "every round is missing, so cover pays");
        assertFalse(book.settlementPending());
        vm.startPrank(bob);
        token.approve(address(pool), 1 ether);
        assertGt(pool.deposit(1 ether, 1), 0);
        vm.stopPrank();
    }

    /// Ownership checks run before the gate: a stranger with no shares sees InsufficientShares.
    function test_strangerRedeemFailsOnSharesBeforeTheGate() public {
        _open(alice, 6, 5000, 10 ether);
        _certify(START + 5);
        vm.expectRevert(CoverPool.InsufficientShares.selector);
        vm.prank(bob);
        pool.redeem(1, 1);
        vm.expectRevert(CoverPool.InvalidAmount.selector);
        vm.prank(lp);
        pool.deposit(0, 1);
    }

    /// Settling ids out of order with the same and different ends keeps the earliest end exact.
    function testFuzz_settlementOrderNeverLeavesTheGateWrong(uint8 orderSeed) public {
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        for (uint256 i; i < 8; ++i) {
            _open(alice, durations[i % 4], 5000, 1 ether);
        }
        _certify(START + 143);
        uint256 settled;
        uint256 cursor = orderSeed;
        while (settled < 8) {
            uint256 id = cursor % 8 + 1;
            cursor = cursor / 2 + 3;
            if (book.getPolicy(id).status != PolicyBook.Status.Open) {
                for (id = 1; book.getPolicy(id).status != PolicyBook.Status.Open; ++id) {}
            }
            assertTrue(book.settlementPending());
            book.settle(id);
            ++settled;
            uint64 earliest;
            for (uint256 j = 1; j <= 8; ++j) {
                PolicyBook.Policy memory p = book.getPolicy(j);
                if (p.status == PolicyBook.Status.Open && (earliest == 0 || p.endRound < earliest)) {
                    earliest = p.endRound;
                }
            }
            assertEq(book.earliestOpenEnd(), earliest);
            assertEq(book.openPolicyCount(), 8 - settled);
        }
        assertFalse(book.settlementPending());
    }
}
