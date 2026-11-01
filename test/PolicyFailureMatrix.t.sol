// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {PolicyBook} from "src/PolicyBook.sol";
import {CoreReader} from "src/CoreReader.sol";
import {CoverPool} from "src/CoverPool.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract PolicyFailureMatrixTest is CoverFixture {
    // Independent integer thresholds: ceil(N * T), pinned for all twelve supported products.
    function test_everyProductImmediatelyBelowAtAndAboveItsThreshold() public {
        uint16[36] memory zeros;
        uint64 cursor = START;
        uint256 totalPremium;
        for (uint256 product; product < 12; ++product) {
            uint16 n = _duration(product);
            for (uint16 edge; edge < 3; ++edge) {
                uint16 z = _requiredZeros(product) - 1 + edge;
                uint256 slot = product * 3 + edge;
                zeros[slot] = z;
                (uint256 id, uint256 premium) = _openAt(alice, cursor, n, _threshold(product), 1 ether);
                assertEq(id, slot + 1);
                totalPremium += premium;
                // Work magnitudes vary, but each present checkpoint contributes just one active round.
                for (uint64 active; active < n - z; ++active) {
                    core.record(cursor + active, active + 1);
                }
                cursor += n;
            }
        }
        _certify(cursor - 1);
        uint256 holderBefore = token.balanceOf(alice);
        uint256 settlerBefore = token.balanceOf(bob);
        uint256 totalPayout;
        for (uint256 id = 36; id > 0; --id) {
            uint256 expected = (id - 1) % 3 == 0 ? 0 : 1 ether;
            vm.prank(bob);
            assertEq(book.settle(id), expected);
            PolicyBook.Policy memory policy = book.getPolicy(id);
            assertEq(policy.zeroRounds, zeros[id - 1]);
            assertEq(
                uint8(policy.status),
                uint8(expected == 0 ? PolicyBook.Status.Expired : PolicyBook.Status.Paid)
            );
            (address beneficiary, uint256 reservation) = pool.reservations(id);
            assertEq(beneficiary, address(0));
            assertEq(reservation, 0);
            assertTrue(pool.usedPolicyIds(id));
            totalPayout += expected;
        }
        assertEq(totalPayout, 24 ether);
        assertEq(token.balanceOf(alice), holderBefore + totalPayout);
        assertEq(token.balanceOf(bob), settlerBefore);
        assertEq(pool.totalAssets(), 1000 ether + totalPremium - totalPayout);
        assertEq(pool.reserved(), 0);
    }

    function test_oldQuoteCannotOpenAfterStartRoundBecomesCurrent() public {
        (uint256 premium,) = book.quote(START, 6, 5000, 100 ether);
        vm.prank(alice);
        token.approve(address(book), premium);
        uint256 balance = token.balanceOf(alice);
        vm.warp(uint256(GENESIS) + uint256(START - 1) * 600);
        vm.expectRevert(abi.encodeWithSelector(PolicyBook.StartNotFuture.selector, START, uint64(100), START));
        vm.prank(alice);
        book.openPolicy(START, 6, 5000, 100 ether, premium, block.timestamp);
        _assertPurchaseAbsent(1, balance, premium);
    }

    function test_holderBalanceFailureAfterApprovalDoesNotConsumeAnIdOrAllowance() public {
        (uint256 premium,) = book.quote(START, 6, 5000, 100 ether);
        vm.startPrank(alice);
        token.approve(address(book), premium);
        token.transfer(bob, token.balanceOf(alice) - premium + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, premium - 1, premium
            )
        );
        book.openPolicy(START, 6, 5000, 100 ether, premium, block.timestamp);
        vm.stopPrank();
        _assertPurchaseAbsent(1, premium - 1, premium);
        vm.prank(bob);
        token.transfer(alice, 1);
        vm.prank(alice);
        assertEq(book.openPolicy(START, 6, 5000, 100 ether, premium, block.timestamp), 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, address(book)), 0);
    }

    function test_unsolicitedBookBalanceCannotSubsidizeOrDivertPremiums() public {
        vm.prank(bob);
        token.transfer(address(book), 77 ether);
        uint256 buyerBefore = token.balanceOf(alice);
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        assertEq(token.balanceOf(alice), buyerBefore - premium);
        assertEq(token.balanceOf(address(book)), 77 ether);
        assertEq(pool.totalAssets(), 1000 ether + premium);
        assertEq(token.allowance(address(book), address(pool)), 0);
        _certify(START + 5);
        book.settle(id);
        assertEq(token.balanceOf(address(book)), 77 ether);
        assertEq(token.balanceOf(alice), buyerBefore - premium + 100 ether);
    }

    function test_snapshotReadFailuresPreserveOpenPolicyAndPermitRetry() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        _certify(START + 5);
        bytes[3] memory reads = [
            abi.encodeCall(core.implementationCodeVersion, ()),
            abi.encodeCall(core.configuration, ()),
            abi.encodeCall(core.state, ())
        ];
        bytes32 beforeState = _settlementState(id);
        for (uint256 i; i < reads.length; ++i) {
            vm.mockCallRevert(address(core), reads[i], abi.encodeWithSignature("UpstreamFailure()"));
            vm.expectRevert(CoreReader.CoreUnavailable.selector);
            vm.prank(bob);
            book.settle(id);
            assertEq(_settlementState(id), beforeState);
            vm.clearMockedCalls();
        }
        vm.prank(bob);
        assertEq(book.settle(id), 100 ether);
    }

    function test_secondPageFailureCannotPartiallySettleOrReleaseCover() public {
        (uint256 id,) = _open(alice, 24, 3000, 100 ether);
        for (uint64 i; i < 17; ++i) {
            core.record(START + i, 1);
        }
        _certify(START + 23);
        bytes memory secondRead = abi.encodeCall(core.roundPage, (START + 15, START + 23, 16));
        bytes32 beforeState = _settlementState(id);
        vm.mockCallRevert(address(core), secondRead, "page unavailable");
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        book.settle(id);
        assertEq(_settlementState(id), beforeState);
        vm.clearMockedCalls();
        ISqueekCore.RoundPage memory page = core.roundPage(START + 15, START + 23, 16);
        page.rounds[0].cumulativeBlockUnits = 0;
        vm.mockCall(address(core), secondRead, abi.encode(page));
        vm.expectRevert(CoreReader.MalformedPage.selector);
        book.settle(id);
        assertEq(_settlementState(id), beforeState);
        vm.clearMockedCalls();
        assertEq(book.settle(id), 0); // Seven zeros fall below the 8/24 trigger.
        assertEq(book.getPolicy(id).zeroRounds, 7);
        assertEq(pool.reserved(), 0);
    }

    function test_frontierOneShortRejectsEvenFullyAvailableActiveRecords() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        for (uint64 i; i < 6; ++i) {
            core.record(START + i, 1);
        }
        _certify(START + 4);
        bytes32 beforeState = _settlementState(id);
        // Unknown history must be rejected before roundPage is even consulted.
        vm.mockCallRevert(address(core), abi.encodeWithSelector(core.roundPage.selector), "must not read");
        vm.expectRevert(abi.encodeWithSelector(CoreReader.UnknownRounds.selector, START + 5, START + 4));
        book.settle(id);
        assertEq(_settlementState(id), beforeState);
        vm.clearMockedCalls();
        _certify(START + 5);
        assertEq(book.settle(id), 0);
    }

    function test_expiredPolicyCannotBeReplayedAfterFurtherCertification() public {
        (uint256 id,) = _open(alice, 6, 7000, 100 ether);
        core.record(START, 1);
        core.record(START + 1, 1);
        _certify(START + 5);
        assertEq(book.settle(id), 0);
        bytes32 finished = _settlementState(id);
        _certify(START + 100);
        vm.expectRevert(PolicyBook.PolicyNotOpen.selector);
        vm.prank(owner);
        book.settle(id);
        assertEq(_settlementState(id), finished);
    }

    function test_bothPausesStillAllowFreeLiquidityWithdrawal() public {
        (uint256 id,) = _open(alice, 6, 5000, 900 ether);
        vm.prank(owner);
        book.setPaused(true);
        core.setPaused(true);
        uint256 shares = pool.sharesOf(lp) / 100;
        uint256 expected = pool.previewRedeem(shares);
        uint256 before = token.balanceOf(lp);
        vm.prank(lp);
        assertEq(pool.redeem(shares, expected), expected);
        assertEq(token.balanceOf(lp), before + expected);
        assertEq(pool.reserved(), 900 ether);
        _certify(START + 5);
        assertEq(book.settle(id), 900 ether);
        _assertSolvent();
    }

    function _openAt(address buyer, uint64 start, uint16 n, uint16 t, uint256 cover)
        private
        returns (uint256 id, uint256 premium)
    {
        (premium,) = book.quote(start, n, t, cover);
        vm.startPrank(buyer);
        token.approve(address(book), premium);
        id = book.openPolicy(start, n, t, cover, premium, block.timestamp);
        vm.stopPrank();
    }

    function _duration(uint256 product) private pure returns (uint16) {
        uint16[4] memory values = [uint16(6), 12, 24, 144];
        return values[product / 3];
    }

    function _threshold(uint256 product) private pure returns (uint16) {
        uint16[3] memory values = [uint16(3000), 5000, 7000];
        return values[product % 3];
    }

    function _requiredZeros(uint256 product) private pure returns (uint16) {
        uint16[12] memory values = [uint16(2), 3, 5, 4, 6, 9, 8, 12, 17, 44, 72, 101];
        return values[product];
    }

    function _assertPurchaseAbsent(uint256 id, uint256 buyerBalance, uint256 allowance) private view {
        assertEq(book.nextPolicyId(), id);
        assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.None));
        assertFalse(pool.usedPolicyIds(id));
        (address beneficiary, uint256 cover) = pool.reservations(id);
        assertEq(beneficiary, address(0));
        assertEq(cover, 0);
        assertEq(pool.totalAssets(), 1000 ether);
        assertEq(pool.reserved(), 0);
        assertEq(token.balanceOf(alice), buyerBalance);
        assertEq(token.allowance(alice, address(book)), allowance);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.allowance(address(book), address(pool)), 0);
    }

    function _settlementState(uint256 id) private view returns (bytes32) {
        (address beneficiary, uint256 cover) = pool.reservations(id);
        return keccak256(
            abi.encode(
                book.getPolicy(id),
                book.nextPolicyId(),
                beneficiary,
                cover,
                pool.reserved(),
                pool.totalAssets(),
                pool.totalShares(),
                pool.usedPolicyIds(id),
                token.balanceOf(alice),
                token.balanceOf(bob),
                token.balanceOf(address(pool))
            )
        );
    }
}
