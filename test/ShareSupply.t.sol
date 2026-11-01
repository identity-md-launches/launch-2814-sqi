// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoverPool} from "../src/CoverPool.sol";

/// @notice Share-supply bounds after repeated complete losses: the supply can never overflow, worthless
/// shares are retired only when accounted assets are zero, and every solvent holder keeps redeeming.
contract ShareSupplyTest is CoverFixture {
    /// @dev LP buys cover on the entire pool, withdraws the premium, and the window certifies empty.
    /// Ends with totalAssets == 0 and reserved == 0 while every share minted so far stays outstanding.
    function _completeLossCycle() internal {
        uint256 cover = pool.freeAssets();
        (, uint64 current,) = reader.snapshot();
        uint64 start = current + 1;
        (uint256 premium,) = book.quote(start, 6, 5000, cover);
        vm.startPrank(lp);
        token.approve(address(book), premium);
        uint256 id = book.openPolicy(start, 6, 5000, cover, premium, block.timestamp);
        uint256 shares = _sharesWorth(lp, premium);
        assertEq(pool.redeem(shares, premium), premium);
        vm.stopPrank();
        _certify(start + 5);
        assertEq(book.settle(id), cover);
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.reserved(), 0);
    }

    function _recapitalize(uint256 amount) internal {
        vm.startPrank(lp);
        token.approve(address(pool), amount);
        pool.deposit(amount, 1);
        vm.stopPrank();
    }

    function _sharesWorth(address holder, uint256 assets) internal view returns (uint256) {
        uint256 low;
        uint256 high = pool.sharesOf(holder);
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (pool.previewRedeem(mid) < assets) low = mid + 1;
            else high = mid;
        }
        return low;
    }

    function test_recapitalizationSucceedsAfterThreeCompleteLossesByRetiringWorthlessShares() public {
        uint256 supplyBefore;
        for (uint256 i; i < 3; ++i) {
            _completeLossCycle();
            supplyBefore = pool.totalShares();
            assertGt(supplyBefore, 0);
            if (i < 2) _recapitalize(1000 ether);
        }
        assertGt(supplyBefore, 1e60);
        assertEq(pool.shareEpoch(), 0);
        uint256 staleShares = pool.sharesOf(lp);
        assertEq(pool.previewRedeem(staleShares), 0);

        // The bounded supply cannot represent 1 SQI against ~1e68 worthless shares: they are retired.
        uint256 expected = pool.previewDeposit(1 ether);
        assertEq(expected, 1 ether * pool.VIRTUAL_SHARES());
        vm.startPrank(bob);
        token.approve(address(pool), 1 ether);
        vm.expectEmit(address(pool));
        emit CoverPool.SharesRetired(0, supplyBefore);
        uint256 minted = pool.deposit(1 ether, expected);
        vm.stopPrank();
        assertEq(minted, expected);
        assertEq(pool.shareEpoch(), 1);
        assertEq(pool.totalShares(), minted);
        assertEq(pool.totalAssets(), 1 ether);
        assertEq(pool.sharesOf(lp), 0);
        assertEq(pool.sharesOfEpoch(0, lp), staleShares);
        vm.prank(lp);
        vm.expectRevert(CoverPool.InsufficientShares.selector);
        pool.redeem(1, 1);
        vm.prank(bob);
        assertEq(pool.redeem(minted, 1 ether), 1 ether);
        _assertSolvent();
    }

    function test_sharesWithValueAreNeverRetiredAndOverflowingDepositsRevertCleanly() public {
        for (uint256 i; i < 3; ++i) {
            _completeLossCycle();
            if (i < 2) _recapitalize(1000 ether);
        }
        // One atom of value: the supply still represents it, so nothing is retired...
        _recapitalize(1);
        assertEq(pool.shareEpoch(), 0);
        assertEq(pool.totalAssets(), 1);
        // ...and a deposit the supply cannot represent is refused rather than expropriating that atom.
        vm.expectRevert(CoverPool.ShareSupplyExhausted.selector);
        pool.previewDeposit(1 ether);
        vm.startPrank(bob);
        token.approve(address(pool), 1 ether);
        vm.expectRevert(CoverPool.ShareSupplyExhausted.selector);
        pool.deposit(1 ether, 1);
        vm.stopPrank();
        // Redeeming the residual value keeps working and clears the way for retirement.
        uint256 keep = pool.totalShares() / 2 - pool.VIRTUAL_SHARES();
        uint256 burn = pool.sharesOf(lp) - keep;
        vm.prank(lp);
        assertEq(pool.redeem(burn, 1), 1);
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.totalShares(), keep);
        vm.startPrank(bob);
        pool.deposit(1 ether, 1);
        vm.stopPrank();
        assertEq(pool.shareEpoch(), 1);
        assertEq(pool.previewRedeem(pool.sharesOf(bob)), 1 ether);
    }

    function test_supplyCapRejectsTheDepositThatWouldBreakPreviewsAndVictimStaysLiquid() public {
        for (uint256 i; i < 3; ++i) {
            _completeLossCycle();
            if (i < 2) _recapitalize(1000 ether);
        }
        // Shape the supply so totalShares + VIRTUAL_SHARES == 2**196 with zero assets, as an attacker would.
        _recapitalize(1);
        uint256 retained = (uint256(1) << 196) - pool.VIRTUAL_SHARES();
        uint256 burn = pool.sharesOf(lp) - retained;
        vm.prank(lp);
        assertEq(pool.redeem(burn, 1), 1);
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.totalShares() + pool.VIRTUAL_SHARES(), uint256(1) << 196);

        vm.startPrank(bob);
        token.approve(address(pool), 1 ether);
        uint256 victimShares = pool.deposit(1 ether, 1);
        vm.stopPrank();
        assertEq(victimShares, 1 ether << 196);

        // This deposit would make totalShares + VIRTUAL_SHARES overflow. It is refused.
        uint256 topUp = (uint256(1) << 60) - 1 - 1 ether;
        vm.startPrank(lp);
        token.approve(address(pool), topUp);
        vm.expectRevert(CoverPool.ShareSupplyExhausted.selector);
        pool.deposit(topUp, 1);
        vm.stopPrank();
        assertLe(pool.totalShares(), pool.MAX_TOTAL_SHARES());

        // Previews never panic and the honest depositor leaves whole.
        assertEq(pool.previewRedeem(victimShares), 1 ether);
        assertGt(pool.previewDeposit(1), 0);
        vm.prank(bob);
        assertEq(pool.redeem(victimShares, 1 ether), 1 ether);
        _assertSolvent();
    }

    function testFuzz_totalSharesNeverExceedCapAndPreviewsNeverPanic(uint96 depositSeed, uint8 cycles)
        public
    {
        uint256 rounds = bound(cycles, 0, 3);
        for (uint256 i; i < rounds; ++i) {
            _completeLossCycle();
            if (i + 1 < rounds) _recapitalize(1000 ether);
        }
        uint256 amount = bound(depositSeed, 1, 10_000 ether);
        vm.startPrank(bob);
        token.approve(address(pool), amount);
        (bool ok, bytes memory data) = address(pool).call(abi.encodeCall(pool.deposit, (amount, 1)));
        vm.stopPrank();
        if (!ok) {
            assertEq(bytes4(data), CoverPool.ShareSupplyExhausted.selector);
        } else {
            assertApproxEqAbs(pool.previewRedeem(pool.sharesOf(bob)), amount, 1);
        }
        assertLe(pool.totalShares(), pool.MAX_TOTAL_SHARES());
        pool.previewRedeem(pool.totalShares());
        _assertSolvent();
    }
}
