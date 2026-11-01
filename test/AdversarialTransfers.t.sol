// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {AdversarialToken} from "./helpers/AdversarialToken.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AdversarialTransfersTest is CoverFixture {
    AdversarialToken internal malicious;
    CoverPool internal guardedPool;
    PolicyBook internal guardedBook;

    function setUp() public override {
        super.setUp();
        malicious = new AdversarialToken();
        guardedPool = new CoverPool(owner, address(malicious));
        guardedBook =
            new PolicyBook(owner, address(malicious), address(model), address(guardedPool), address(reader));
        vm.prank(owner);
        guardedPool.setPolicyBook(address(guardedBook));
        malicious.mint(lp, 1000 ether);
        malicious.mint(alice, 100 ether);
    }

    function test_falseReturnAndFeeDepositsRollBack() public {
        vm.prank(lp);
        malicious.approve(address(guardedPool), 1000 ether);
        malicious.configure(AdversarialToken.Mode.ReturnFalse, lp, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(malicious))
        );
        vm.prank(lp);
        guardedPool.deposit(1000 ether, 1);
        malicious.configure(AdversarialToken.Mode.Fee, lp, address(0), "");
        vm.expectRevert(CoverPool.TokenAmountMismatch.selector);
        vm.prank(lp);
        guardedPool.deposit(1000 ether, 1);
        assertEq(guardedPool.totalShares(), 0);
        assertEq(guardedPool.totalAssets(), 0);
        assertEq(malicious.balanceOf(lp), 1000 ether);
    }

    function test_noReturnTokenSupportedBySafeERC20() public {
        malicious.configure(AdversarialToken.Mode.NoReturn, address(0), address(0), "");
        _fundPool();
        uint256 id = _openGuarded();
        _certify(START + 5);
        guardedBook.settle(id);
        assertEq(malicious.balanceOf(alice), 194 ether);
        assertEq(guardedPool.reserved(), 0);
    }

    function test_depositAndRedeemReentrancyBlocked() public {
        malicious.configure(
            AdversarialToken.Mode.Callback,
            lp,
            address(guardedPool),
            abi.encodeCall(guardedPool.deposit, (1, 1))
        );
        _fundPool();
        _assertCallbackGuarded();
        malicious.configure(
            AdversarialToken.Mode.Callback,
            address(guardedPool),
            address(guardedPool),
            abi.encodeCall(guardedPool.redeem, (1, 1))
        );
        uint256 shares = guardedPool.sharesOf(lp);
        vm.prank(lp);
        guardedPool.redeem(shares, 1);
        _assertCallbackGuarded();
        assertEq(guardedPool.totalAssets(), 0);
    }

    function test_openReentrancyBlockedDuringPremiumReceipt() public {
        _fundPool();
        malicious.configure(
            AdversarialToken.Mode.Callback,
            alice,
            address(guardedBook),
            abi.encodeCall(guardedBook.openPolicy, (START, 6, 5000, 100 ether, 100 ether, block.timestamp))
        );
        _openGuarded();
        _assertCallbackGuarded();
        assertEq(guardedBook.nextPolicyId(), 2);
        assertEq(guardedPool.reserved(), 100 ether);
    }

    function test_settlementReentrancyBlockedDuringPayout() public {
        _fundPool();
        uint256 id = _openGuarded();
        _certify(START + 5);
        malicious.configure(
            AdversarialToken.Mode.Callback,
            address(guardedPool),
            address(guardedBook),
            abi.encodeCall(guardedBook.settle, (id))
        );
        guardedBook.settle(id);
        _assertCallbackGuarded();
        assertEq(malicious.balanceOf(alice), 194 ether);
        assertEq(guardedPool.reserved(), 0);
    }

    function test_failedPayoutRollsBackAndCanBeRetried() public {
        _fundPool();
        uint256 id = _openGuarded();
        _certify(START + 5);
        malicious.configure(AdversarialToken.Mode.ReturnFalse, address(guardedPool), address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(malicious))
        );
        guardedBook.settle(id);
        assertEq(uint8(guardedBook.getPolicy(id).status), uint8(PolicyBook.Status.Open));
        assertEq(guardedPool.reserved(), 100 ether);
        assertEq(guardedPool.totalAssets(), 1006 ether);
        malicious.configure(AdversarialToken.Mode.Normal, address(0), address(0), "");
        assertEq(guardedBook.settle(id), 100 ether);
        assertEq(guardedPool.totalAssets(), 906 ether);
    }

    function test_feeOnEitherPremiumLegRollsBackWholePurchase() public {
        _fundPool();
        vm.prank(alice);
        malicious.approve(address(guardedBook), 100 ether);
        malicious.configure(AdversarialToken.Mode.Fee, alice, address(0), "");
        vm.expectRevert(PolicyBook.TokenAmountMismatch.selector);
        vm.prank(alice);
        guardedBook.openPolicy(START, 6, 5000, 100 ether, 100 ether, block.timestamp);
        malicious.configure(AdversarialToken.Mode.Fee, address(guardedBook), address(0), "");
        vm.expectRevert(CoverPool.TokenAmountMismatch.selector);
        vm.prank(alice);
        guardedBook.openPolicy(START, 6, 5000, 100 ether, 100 ether, block.timestamp);
        assertEq(guardedBook.nextPolicyId(), 1);
        assertEq(guardedPool.reserved(), 0);
        assertEq(guardedPool.totalAssets(), 1000 ether);
        assertEq(malicious.balanceOf(alice), 100 ether);
    }

    function _fundPool() private {
        vm.startPrank(lp);
        malicious.approve(address(guardedPool), 1000 ether);
        guardedPool.deposit(1000 ether, 1);
        vm.stopPrank();
    }

    function _openGuarded() private returns (uint256 id) {
        (uint256 premium,) = guardedBook.quote(START, 6, 5000, 100 ether);
        vm.startPrank(alice);
        malicious.approve(address(guardedBook), premium);
        id = guardedBook.openPolicy(START, 6, 5000, 100 ether, premium, block.timestamp);
        vm.stopPrank();
    }

    function _assertCallbackGuarded() private view {
        assertFalse(malicious.callbackSucceeded());
        assertEq(
            malicious.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }
}
