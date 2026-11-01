// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PremiumModel} from "src/PremiumModel.sol";
import {CoverTerms} from "src/CoverTerms.sol";

/// forge-config: default.fuzz.runs = 1000
contract PremiumArithmeticPropertiesTest is Test {
    PremiumModel private model;

    function setUp() public {
        vm.chainId(11_155_111);
        model = new PremiumModel(address(this));
    }

    function testFuzz_fullUtilizationSupportsUint256Amounts(
        uint256 coverSeed,
        uint16 baseSeed,
        uint16 slopeSeed
    ) public {
        uint256 cover = bound(coverSeed, 1, type(uint256).max);
        uint16 base = uint16(bound(baseSeed, 1, 10_000));
        uint16 slope = uint16(bound(slopeSeed, 0, 10_000 - base));
        model.setRate(144, 7000, base, slope);
        (uint256 premium, uint256 rate) =
            model.quote(144, 7000, cover, type(uint256).max, type(uint256).max - cover);
        assertEq(rate, uint256(base) + slope);
        // Division first plus a small remainder is an independent overflow-safe oracle.
        // In particular, no copy of the production Math.mulDiv is used here.
        uint256 whole = (cover / 10_000) * rate;
        uint256 remainder = (cover % 10_000) * rate;
        uint256 expected = whole + remainder / 10_000 + (remainder % 10_000 == 0 ? 0 : 1);
        assertEq(premium, expected);
        assertGt(premium, 0);
        assertLe(premium, cover);
    }

    function testFuzz_bothRoundingStepsChooseTheLeastSufficientInteger(
        uint128 assetsSeed,
        uint128 reservedSeed,
        uint128 coverSeed,
        uint16 baseSeed,
        uint16 slopeSeed
    ) public {
        uint256 assets = bound(assetsSeed, 1, type(uint128).max);
        uint256 reserved = bound(reservedSeed, 0, assets - 1);
        uint256 cover = bound(coverSeed, 1, assets - reserved);
        uint16 base = uint16(bound(baseSeed, 1, 10_000));
        uint16 slope = uint16(bound(slopeSeed, 0, 10_000 - base));
        model.setRate(12, 3000, base, slope);
        (uint256 premium, uint256 rate) = model.quote(12, 3000, cover, assets, reserved);
        uint256 surcharge = rate - base;
        uint256 utilizationNumerator = (reserved + cover) * slope;
        assertGe(surcharge * assets, utilizationNumerator);
        if (surcharge > 0) assertLt((surcharge - 1) * assets, utilizationNumerator);
        assertGe(premium * 10_000, cover * rate);
        assertLt((premium - 1) * 10_000, cover * rate);
        assertLe(rate, 10_000);
        assertLe(premium, cover);
    }

    function testFuzz_moreLiquidityNeverRaisesTheSameCoverPremium(
        uint128 assetsSeed,
        uint128 coverSeed,
        uint128 reservedSeed,
        uint128 extraSeed
    ) public {
        uint256 assets = bound(assetsSeed, 1, type(uint128).max);
        uint256 reserved = bound(reservedSeed, 0, assets - 1);
        uint256 cover = bound(coverSeed, 1, assets - reserved);
        model.setRate(24, 5000, 1, 9999);
        (uint256 oldPremium, uint256 oldRate) = model.quote(24, 5000, cover, assets, reserved);
        (uint256 newPremium, uint256 newRate) = model.quote(24, 5000, cover, assets + extraSeed, reserved);
        assertLe(newPremium, oldPremium);
        assertLe(newRate, oldRate);
    }

    function test_maximumCoverAtMaximumRateIsExactAndDoesNotOverflow() public {
        model.setRate(6, 5000, 1, 9999);
        (uint256 premium, uint256 rate) = model.quote(6, 5000, type(uint256).max, type(uint256).max, 0);
        assertEq(rate, 10_000);
        assertEq(premium, type(uint256).max);
        (premium, rate) = model.quote(6, 5000, 1, type(uint256).max, 0);
        assertEq(rate, 2);
        assertEq(premium, 1);
    }

    function test_maximumReservedAndEmptyAssetsFailWithLiquidityError() public {
        model.setRate(6, 5000, 1, 0);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, 1, type(uint256).max, type(uint256).max);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, 1, 0, type(uint256).max);
        vm.expectRevert(PremiumModel.InsufficientLiquidity.selector);
        model.quote(6, 5000, type(uint256).max, type(uint256).max, 1);
    }

    function test_invalidRateCannotOverwriteConfiguredTerms() public {
        model.setRate(6, 5000, 1, 9999);
        vm.expectRevert(PremiumModel.InvalidRate.selector);
        model.setRate(6, 5000, type(uint16).max, type(uint16).max);
        vm.expectRevert(PremiumModel.InvalidRate.selector);
        model.setRate(6, 5000, 0, 0);
        (uint16 base, uint16 slope, bool configured) = model.rates(6, 5000);
        assertEq(base, 1);
        assertEq(slope, 9999);
        assertTrue(configured);
    }

    function testFuzz_unsupportedDurationCannotBeConfiguredOrQuoted(uint16 seed) public {
        uint16 n = seed;
        if (n == 6 || n == 12 || n == 24 || n == 144) n = 0;
        vm.expectRevert(CoverTerms.InvalidDuration.selector);
        model.setRate(n, 5000, 1, 0);
        vm.expectRevert(CoverTerms.InvalidDuration.selector);
        model.quote(n, 5000, 1, 1, 0);
    }

    function testFuzz_unsupportedThresholdCannotBeConfiguredOrQuoted(uint16 seed) public {
        uint16 t = seed;
        if (t == 3000 || t == 5000 || t == 7000) t = 0;
        vm.expectRevert(CoverTerms.InvalidThreshold.selector);
        model.setRate(6, t, 1, 0);
        vm.expectRevert(CoverTerms.InvalidThreshold.selector);
        model.quote(6, t, 1, 1, 0);
    }
}
