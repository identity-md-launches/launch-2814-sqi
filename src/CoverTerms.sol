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

    /// @dev Smallest number of zero-work rounds that triggers: ceil(rounds * thresholdBps / BPS), in 1..rounds.
    function requiredZeroRounds(uint16 rounds, uint16 thresholdBps) internal pure returns (uint16) {
        return uint16((uint256(rounds) * thresholdBps + BPS - 1) / BPS);
    }

    /// @dev Outcome fixed by a certified prefix of `certifiedRounds` rounds holding `zeroRounds` zero-work
    /// rounds. Covered once the prefix alone meets the threshold; expired once the uncertified remainder
    /// cannot reach it. Undecided otherwise. A fully certified window is always decided.
    function outcome(uint16 zeroRounds, uint16 certifiedRounds, uint16 rounds, uint16 thresholdBps)
        internal
        pure
        returns (bool decided, bool covered)
    {
        uint16 required = requiredZeroRounds(rounds, thresholdBps);
        if (zeroRounds >= required) return (true, true);
        if (uint256(zeroRounds) + (rounds - certifiedRounds) < required) return (true, false);
        return (false, false);
    }

    /// @dev Earliest round at which `required` zero-work rounds can have been certified given the prefix
    /// through `lastCertified` (startRound - 1 when nothing is certified yet) holding `zeroRounds`.
    function nextDecideRound(uint64 lastCertified, uint16 zeroRounds, uint16 required)
        internal
        pure
        returns (uint64)
    {
        return lastCertified + (required - zeroRounds);
    }
}
