// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoverPoolTest is CoverFixture {
    function test_equalDepositsReceiveEqualSharesAndRedeemCapital() public {
        uint256 before = token.balanceOf(bob);
        vm.startPrank(bob);
        token.approve(address(pool), 1000 ether);
        uint256 shares = pool.deposit(1000 ether, 1000 ether * 1e6);
        assertEq(shares, pool.sharesOf(lp));
        assertEq(pool.redeem(shares, 1000 ether), 1000 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), before);
        _assertSolvent();
    }

    function test_directDonationsCannotInflateSharePrice() public {
        uint256 expected = pool.previewDeposit(100 ether);
        vm.prank(bob);
        token.transfer(address(pool), 500 ether);
        assertEq(pool.previewDeposit(100 ether), expected);
        assertEq(pool.totalAssets(), 1000 ether);
        vm.startPrank(alice);
        token.approve(address(pool), 100 ether);
        uint256 shares = pool.deposit(100 ether, expected);
        assertEq(pool.redeem(shares, 100 ether), 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(address(pool)), 1500 ether);
        _assertSolvent();
    }

    function test_lockedCapitalCannotBeWithdrawnButFreeCapitalCan() public {
        _open(alice, 6, 5000, 900 ether);
        uint256 allShares = pool.sharesOf(lp);
        vm.expectRevert(CoverPool.InsufficientFreeAssets.selector);
        vm.prank(lp);
        pool.redeem(allShares, 1);
        uint256 partialShares = allShares / 10;
        vm.prank(lp);
        pool.redeem(partialShares, 1);
        assertEq(pool.reserved(), 900 ether);
        _assertSolvent();
    }

    function test_premiumsAccrueToLPAndLossReducesShareValue() public {
        uint256 shares = pool.sharesOf(lp);
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 100 ether);
        assertApproxEqAbs(pool.previewRedeem(shares), 1000 ether + premium, 1);
        _certify(START + 5);
        book.settle(id);
        uint256 assets = pool.previewRedeem(shares);
        assertApproxEqAbs(assets, 900 ether + premium, 1);
        uint256 before = token.balanceOf(lp);
        vm.prank(lp);
        assertEq(pool.redeem(shares, assets), assets);
        assertEq(token.balanceOf(lp), before + assets);
        assertEq(pool.totalShares(), 0);
        assertLe(pool.totalAssets(), 1);
        _assertSolvent();
    }

    function test_recapitalizationAfterTotalLossDoesNotDivideByZero() public {
        (uint256 id, uint256 premium) = _open(alice, 6, 5000, 1000 ether);
        uint256 shares = Math.mulDiv(
            premium, pool.totalShares() + pool.VIRTUAL_SHARES(), pool.totalAssets() + 1, Math.Rounding.Ceil
        );
        vm.prank(lp);
        assertEq(pool.redeem(shares, premium), premium);
        assertEq(pool.totalAssets(), 1000 ether);
        _certify(START + 5);
        book.settle(id);
        assertEq(pool.totalAssets(), 0);
        assertGt(pool.totalShares(), 0);
        vm.startPrank(bob);
        token.approve(address(pool), 100 ether);
        shares = pool.deposit(100 ether, 1);
        assertApproxEqAbs(pool.redeem(shares, 1), 100 ether, 1);
        vm.stopPrank();
        _assertSolvent();
    }

    function test_depositAndRedeemSlippageAndZeroAmounts() public {
        uint256 depositQuote = pool.previewDeposit(1 ether);
        uint256 lpShares = pool.sharesOf(lp);
        vm.startPrank(lp);
        vm.expectRevert(CoverPool.InvalidAmount.selector);
        pool.deposit(0, 1);
        vm.expectRevert(CoverPool.InvalidAmount.selector);
        pool.deposit(1, 0);
        vm.expectRevert(CoverPool.Slippage.selector);
        pool.deposit(1 ether, depositQuote + 1);
        vm.expectRevert(CoverPool.InvalidAmount.selector);
        pool.redeem(0, 1);
        vm.expectRevert(CoverPool.Slippage.selector);
        pool.redeem(lpShares, 1001 ether);
        vm.expectRevert(CoverPool.InsufficientShares.selector);
        pool.redeem(lpShares + 1, 1);
        vm.stopPrank();
    }

    function test_onlyCallerSharesCanBeRedeemed() public {
        vm.expectRevert(CoverPool.InsufficientShares.selector);
        vm.prank(alice);
        pool.redeem(1, 1);
    }

    function test_onlyBookCanLockOrReleaseCover() public {
        vm.expectRevert(CoverPool.OnlyPolicyBook.selector);
        vm.prank(owner);
        pool.lockCover(1, alice, 1, 1);
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        vm.expectRevert(CoverPool.OnlyPolicyBook.selector);
        vm.prank(owner);
        pool.resolveCover(id, true);
        assertEq(pool.reserved(), 100 ether);
    }

    function test_bookBindingIsOneTimeAndRequiredBeforeDeposit() public {
        CoverPool unbound = new CoverPool(owner, address(token));
        vm.expectRevert(CoverPool.BookNotConfigured.selector);
        unbound.deposit(1, 1);
        vm.prank(owner);
        vm.expectRevert(CoverPool.InvalidBook.selector);
        unbound.setPolicyBook(address(book)); // reciprocal pool address does not match
        vm.prank(owner);
        vm.expectRevert(CoverPool.InvalidBook.selector);
        unbound.setPolicyBook(alice);
        vm.expectRevert(CoverPool.AlreadyConfigured.selector);
        vm.prank(owner);
        pool.setPolicyBook(address(book));
        PolicyBook orphan =
            new PolicyBook(owner, address(token), address(model), address(unbound), address(reader));
        vm.expectRevert(PolicyBook.NotConfigured.selector);
        orphan.quote(START, 6, 5000, 1);
    }

    function test_cannotReuseReservationOrResolveTwiceEvenAsBook() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        vm.expectRevert(CoverPool.InvalidReservation.selector);
        vm.prank(address(book));
        pool.lockCover(id, alice, 1, 1);
        _certify(START + 5);
        book.settle(id);
        vm.expectRevert(CoverPool.InvalidReservation.selector);
        vm.prank(address(book));
        pool.resolveCover(id, true);
        vm.expectRevert(CoverPool.InvalidReservation.selector);
        vm.prank(address(book));
        pool.lockCover(id, alice, 1, 1);
    }

    function test_custodyShortfallBlocksRatherThanCreatesUnbackedShares() public {
        // Only test cheatcodes can remove collateral from the fixed standard token.
        vm.prank(address(pool));
        token.transfer(bob, 1);
        vm.startPrank(lp);
        token.approve(address(pool), 1 ether);
        vm.expectRevert(CoverPool.CustodyShortfall.selector);
        pool.deposit(1 ether, 1);
        vm.expectRevert(CoverPool.CustodyShortfall.selector);
        pool.redeem(1e18, 1);
        vm.stopPrank();
    }

    function testFuzz_roundTripCannotCreateAssets(uint96 depositSeed, uint96 donationSeed) public {
        uint256 deposit = bound(depositSeed, 1, 10_000 ether);
        uint256 donation = bound(donationSeed, 0, 10_000 ether);
        vm.prank(alice);
        token.transfer(address(pool), donation);
        uint256 before = token.balanceOf(bob);
        vm.startPrank(bob);
        token.approve(address(pool), deposit);
        uint256 shares = pool.deposit(deposit, 1);
        uint256 returned = pool.redeem(shares, 1);
        vm.stopPrank();
        assertLe(returned, deposit);
        assertLe(token.balanceOf(bob), before);
        _assertSolvent();
    }
}
