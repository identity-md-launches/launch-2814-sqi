// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "./interfaces/ISqueekCore.sol";
import {CoverTerms} from "./CoverTerms.sol";
import {SepoliaOnly} from "./SepoliaOnly.sol";

/// @notice Reads certified V3 history only. Has no privileged role or write path into SqueekCore.
contract CoreReader is SepoliaOnly {
    uint64 public constant ROUND_DURATION = 600;
    uint256 public constant PAGE_SIZE = 16;
    uint64 public constant CORE_VERSION = 3;
    ISqueekCore public immutable core;

    error InvalidCore();
    error CoreUnavailable();
    error UnsupportedCoreVersion();
    error InvalidConfiguration();
    error InconsistentCore();
    error UnknownRounds(uint64 requestedEnd, uint64 frontier);
    error MalformedPage();

    constructor(address core_) {
        if (core_ == address(0)) revert InvalidCore();
        core = ISqueekCore(core_);
    }

    function snapshot() public view returns (uint64 frontier, uint64 currentRound, bool paused) {
        _checkCore();
        ISqueekCore.CoreConfiguration memory config;
        try core.configuration() returns (ISqueekCore.CoreConfiguration memory result) {
            config = result;
        } catch {
            revert CoreUnavailable();
        }
        if (
            config.genesisTimestamp == 0 || config.roundDuration != ROUND_DURATION
                || config.maxRoundsPerBatch != PAGE_SIZE
        ) revert InvalidConfiguration();
        uint256 current = 0;
        if (block.timestamp >= config.genesisTimestamp) {
            current = (block.timestamp - config.genesisTimestamp) / ROUND_DURATION + 1;
        }
        if (current > type(uint64).max) revert InconsistentCore();
        currentRound = uint64(current);
        ISqueekCore.CoreState memory state = _state();
        frontier = state.settledThroughRound;
        if ((current == 0 && frontier != 0) || (current != 0 && frontier >= current)) {
            revert InconsistentCore();
        }
        paused = state.paused;
    }

    /// @notice Counts absent active records only after every requested round is certified.
    /// @dev At most nine 16-record pages for the maximum 144-round policy. Pause does not hide history.
    function countZeroRounds(uint64 startRound, uint16 rounds) external view returns (uint16 zeroRounds) {
        uint64 end = CoverTerms.endRound(startRound, rounds);
        (uint64 frontier,,) = snapshot();
        if (end > frontier) revert UnknownRounds(end, frontier);

        uint64 cursor = startRound - 1;
        uint256 active = 0;
        bool first = true;
        ISqueekCore.LedgerPosition memory previousEnd;
        while (cursor < end) {
            ISqueekCore.RoundPage memory page;
            try core.roundPage(cursor, end, PAGE_SIZE) returns (ISqueekCore.RoundPage memory result) {
                page = result;
            } catch {
                revert CoreUnavailable();
            }
            if (
                page.certifiedThroughRound <= cursor || page.certifiedThroughRound > end
                    || page.rounds.length > PAGE_SIZE
                    || (page.certifiedThroughRound < end && page.rounds.length != PAGE_SIZE)
                    || (!first && !_samePosition(page.start, previousEnd))
            ) revert MalformedPage();

            _validatePage(page, cursor);
            active += page.rounds.length;
            cursor = page.certifiedThroughRound;
            previousEnd = page.end;
            first = false;
        }
        // Strictly increasing record IDs in the certified range imply active <= rounds.
        zeroRounds = uint16(uint256(rounds) - active);
    }

    function _validatePage(ISqueekCore.RoundPage memory page, uint64 cursor) private pure {
        ISqueekCore.LedgerPosition memory position = page.start;
        if (position.workPerThousandBlocks == 0) revert MalformedPage();
        for (uint256 i; i < page.rounds.length; ++i) {
            ISqueekCore.RoundCheckpoint memory record = page.rounds[i];
            if (
                record.roundId <= cursor || record.roundId > page.certifiedThroughRound
                    || record.cumulativeWork <= position.cumulativeWork
                    || record.cumulativeBlockUnits < position.cumulativeBlockUnits
                    || record.workPerThousandBlocks == 0 || record.dataHash == bytes32(0)
            ) revert MalformedPage();
            cursor = record.roundId;
            position = ISqueekCore.LedgerPosition(
                record.cumulativeWork, record.cumulativeBlockUnits, record.workPerThousandBlocks
            );
        }
        if (!_samePosition(position, page.end)) revert MalformedPage();
    }

    function _samePosition(ISqueekCore.LedgerPosition memory a, ISqueekCore.LedgerPosition memory b)
        private
        pure
        returns (bool)
    {
        return a.cumulativeWork == b.cumulativeWork && a.cumulativeBlockUnits == b.cumulativeBlockUnits
            && a.workPerThousandBlocks == b.workPerThousandBlocks;
    }

    function _checkCore() private view {
        if (address(core).code.length == 0) revert CoreUnavailable();
        try core.implementationCodeVersion() returns (uint64 version) {
            if (version != CORE_VERSION) revert UnsupportedCoreVersion();
        } catch {
            revert CoreUnavailable();
        }
    }

    function _state() private view returns (ISqueekCore.CoreState memory result) {
        try core.state() returns (ISqueekCore.CoreState memory state) {
            return state;
        } catch {
            revert CoreUnavailable();
        }
    }
}
