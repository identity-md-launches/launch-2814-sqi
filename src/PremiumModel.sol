// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Managed} from "./Managed.sol";
import {CoverTerms} from "./CoverTerms.sol";

/// @notice Owner-configured testnet premium table with a linear utilization surcharge.
contract PremiumModel is Managed {
    struct Rate {
        uint16 baseBps;
        uint16 slopeBps;
        bool configured;
    }

    mapping(uint16 rounds => mapping(uint16 thresholdBps => Rate)) public rates;

    error InvalidRate();
    error RateNotConfigured();
    error InvalidCover();
    error InsufficientLiquidity();

    event RateSet(uint16 indexed rounds, uint16 indexed thresholdBps, uint16 baseBps, uint16 slopeBps);

    constructor(address owner_) Managed(owner_) {}

    /// @notice Base must be positive; base + maximum surcharge may not exceed the cover amount.
    /// @dev Updates affect new quotes only. Existing policies store their paid premium.
    function setRate(uint16 rounds, uint16 thresholdBps, uint16 baseBps, uint16 slopeBps) external onlyOwner {
        CoverTerms.validate(rounds, thresholdBps);
        if (baseBps == 0 || uint256(baseBps) + slopeBps > CoverTerms.BPS) revert InvalidRate();
        rates[rounds][thresholdBps] = Rate(baseBps, slopeBps, true);
        emit RateSet(rounds, thresholdBps, baseBps, slopeBps);
    }

    /// @return premium Rounded up to token atoms.
    /// @return rateBps Base plus rounded-up surcharge at projected, pre-premium utilization.
    function quote(uint16 rounds, uint16 thresholdBps, uint256 cover, uint256 assets, uint256 reserved)
        external
        view
        returns (uint256 premium, uint256 rateBps)
    {
        CoverTerms.validate(rounds, thresholdBps);
        Rate memory rate = rates[rounds][thresholdBps];
        if (!rate.configured) revert RateNotConfigured();
        if (cover == 0) revert InvalidCover();
        if (reserved > assets || cover > assets - reserved) revert InsufficientLiquidity();
        rateBps = rate.baseBps + Math.mulDiv(reserved + cover, rate.slopeBps, assets, Math.Rounding.Ceil);
        premium = Math.mulDiv(cover, rateBps, CoverTerms.BPS, Math.Rounding.Ceil);
    }
}
