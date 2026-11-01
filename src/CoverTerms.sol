// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library CoverTerms {
    uint256 internal constant BPS = 10_000;

    error InvalidDuration();
    error InvalidThreshold();
    error InvalidStartRound();
    error RoundOverflow();

    function validateDuration(uint16 rounds) internal pure {
        if (rounds != 6 && rounds != 12 && rounds != 24 && rounds != 144) revert InvalidDuration();
    }

    function validate(uint16 rounds, uint16 thresholdBps) internal pure {
        validateDuration(rounds);
        if (thresholdBps != 3000 && thresholdBps != 5000 && thresholdBps != 7000) {
            revert InvalidThreshold();
        }
    }

    function endRound(uint64 startRound, uint16 rounds) internal pure returns (uint64) {
        validateDuration(rounds);
        if (startRound == 0) revert InvalidStartRound();
        uint256 end = uint256(startRound) + rounds - 1;
        if (end > type(uint64).max) revert RoundOverflow();
        return uint64(end);
    }

    function triggered(uint16 zeroRounds, uint16 rounds, uint16 thresholdBps) internal pure returns (bool) {
        return uint256(zeroRounds) * BPS >= uint256(rounds) * thresholdBps;
    }
}
