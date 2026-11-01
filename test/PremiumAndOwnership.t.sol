// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {MockSQK} from "../src/MockSQK.sol";
import {Managed} from "../src/Managed.sol";
import {CoverTerms} from "../src/CoverTerms.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PremiumAndOwnershipTest is CoverFixture {
    function test_tokenMetadataInitialSupplyAndOwnerMint() public {
        MockSQK fresh = new MockSQK(owner);
        assertEq(fresh.name(), "SQI");
        assertEq(fresh.symbol(), "SQI");
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.totalSupply(), 100_000_000 ether);
        assertEq(fresh.balanceOf(owner), fresh.totalSupply());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.mint(alice, 1);
        vm.prank(owner);
        fresh.mint(alice, 123);
        assertEq(fresh.balanceOf(alice), 123);
        assertEq(fresh.totalSupply(), fresh.INITIAL_SUPPLY() + 123);
    }

    function test_pricesMustBeExplicitlyConfigured() public {
        PremiumModel fresh = new PremiumModel(owner);
        vm.expectRevert(PremiumModel.RateNotConfigured.selector);
        fresh.quote(6, 3000, 100 ether, 1000 ether, 0);
        vm.prank(owner);
        fresh.setRate(6, 3000, 100, 1000);
        (uint256 premium, uint256 rate) = fresh.quote(6, 3000, 100 ether, 1000 ether, 0);
        assertEq(rate, 200);
        assertEq(premium, 2 ether);
        vm.expectRevert(PremiumModel.RateNotConfigured.selector);
        fresh.quote(6, 5000, 100 ether, 1000 ether, 0);
    }

    function test_configuredTableHasIndependentTwelveEntries() public {
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        for (uint16 i; i < 4; ++i) {
            for (uint16 j; j < 3; ++j) {
                uint16 rate = 100 + 10 * i + j;
                vm.prank(owner);
                model.setRate(durations[i], thresholds[j], rate, 0);
                (uint256 premium, uint256 quoted) =
                    model.quote(durations[i], thresholds[j], 10_000, 10_000, 0);
                assertEq(quoted, rate);
                assertEq(premium, rate);
            }
        }
    }

    function test_fullUtilizationAndAtomRounding() public view {
        (uint256 premium, uint256 rate) = model.quote(6, 5000, 100, 1000, 900);
        assertEq(rate, 1500);
        assertEq(premium, 15);
        (premium, rate) = model.quote(6, 5000, 1, 1_000_000, 0);
        assertEq(rate, 501);
        assertEq(premium, 1);
    }

    function test_invalidRatesTermsAndLiquidity() public {
        vm.startPrank(owner);
        vm.expectRevert(PremiumModel.InvalidRate.selector);
        model.setRate(6, 5000, 0, 1000);
        vm.expectRevert(PremiumModel.InvalidRate.selector);
        model.setRate(6, 5000, 9001, 1000);
        vm.expectRevert(CoverTerms.InvalidDuration.selector);
        model.setRate(1, 5000, 100, 0);
        vm.expectRevert(CoverTerms.InvalidThreshold.selector);
        model.setRate(6, 4999, 100, 0);
        vm.stopPrank();
        vm.expectRevert(PremiumModel.InvalidCover.selector);
        model.quote(6, 5000, 0, 1000, 0);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, 1, 0, 0);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, 1, 100, 101);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, 2, 100, 99);
    }

    function test_allAdminFunctionsRejectStrangersIncludingFactory() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));
        vm.expectRevert(unauthorized);
        model.setRate(6, 5000, 1, 0);
        vm.expectRevert(unauthorized);
        pool.setPolicyBook(address(book));
        vm.expectRevert(unauthorized);
        book.setPaused(true);
        vm.expectRevert(unauthorized);
        token.mint(alice, 1);
        assertEq(token.owner(), owner);
        assertEq(model.owner(), owner);
        assertEq(pool.owner(), owner);
        assertEq(book.owner(), owner);
    }

    function test_twoStepOwnerHandoverAndNoRenunciation() public {
        vm.prank(owner);
        token.transferOwnership(alice);
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        token.acceptOwnership();
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        token.mint(bob, 1);
        vm.prank(alice);
        token.mint(bob, 1);
        vm.expectRevert(Managed.RenounceDisabled.selector);
        vm.prank(alice);
        token.renounceOwnership();
    }

    function testFuzz_premiumsBoundedAndMonotonic(
        uint96 coverSeed,
        uint96 assetsSeed,
        uint16 baseSeed,
        uint16 slopeSeed
    ) public {
        uint256 assets = bound(assetsSeed, 1, type(uint96).max);
        uint256 cover = bound(coverSeed, 1, assets);
        uint16 base = uint16(bound(baseSeed, 1, 10_000));
        uint16 slope = uint16(bound(slopeSeed, 0, 10_000 - base));
        vm.prank(owner);
        model.setRate(6, 5000, base, slope);
        (uint256 premiumLow, uint256 rateLow) = model.quote(6, 5000, cover, assets, 0);
        (uint256 premiumHigh, uint256 rateHigh) = model.quote(6, 5000, cover, assets, assets - cover);
        assertGt(premiumLow, 0);
        assertLe(premiumLow, premiumHigh);
        assertLe(premiumHigh, cover);
        assertGe(rateLow, base);
        assertLe(rateLow, rateHigh);
        assertEq(rateHigh, uint256(base) + slope);
    }
}
