// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";

/// @dev Test fixture for V3 sparse pagination; never deployed by the manifest.
contract MockCore is ISqueekCore {
    uint64 public genesis;
    uint64 public frontier;
    bool public paused;
    uint64 public version = 3;
    bool public unavailable;
    RoundCheckpoint[] private _records;

    constructor(uint64 genesis_) {
        genesis = genesis_;
    }

    function setFrontier(uint64 value) external {
        frontier = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setVersion(uint64 value) external {
        version = value;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function record(uint64 roundId, uint64 work) external {
        require(work > 0 && roundId > frontier, "fixture: invalid record");
        LedgerPosition memory last = _positionAt(type(uint64).max);
        if (_records.length != 0) require(roundId > _records[_records.length - 1].roundId, "fixture: order");
        _records.push(
            RoundCheckpoint(
                roundId,
                last.cumulativeWork + work,
                last.cumulativeBlockUnits + uint96(work) * 1e9,
                10_875,
                keccak256(abi.encode(roundId, work))
            )
        );
    }

    function implementationCodeVersion() external view returns (uint64) {
        require(!unavailable, "fixture: unavailable");
        return version;
    }

    function configuration() external view returns (CoreConfiguration memory result) {
        require(!unavailable, "fixture: unavailable");
        result.genesisTimestamp = genesis;
        result.roundDuration = 600;
        result.maxWorkPerRound = 10_000;
        result.maxRoundsPerBatch = 16;
        result.initialWorkPerThousandBlocks = 10_875;
        result.targetBlocksPerActiveRound = 40;
        result.difficultySmoothingRounds = 30;
        result.blockUnitsPerBlock = 1e9;
    }

    function state() external view returns (CoreState memory result) {
        require(!unavailable, "fixture: unavailable");
        LedgerPosition memory position = _positionAt(frontier);
        result.settledThroughRound = frontier;
        result.cumulativeWork = position.cumulativeWork;
        result.cumulativeBlockUnits = position.cumulativeBlockUnits;
        result.blockHeight = uint64(position.cumulativeBlockUnits / 1e9);
        result.blockProgress = position.cumulativeBlockUnits % 1e9;
        result.workPerThousandBlocks = position.workPerThousandBlocks;
        result.paused = paused;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory result)
    {
        require(!unavailable, "fixture: unavailable");
        require(afterRound <= throughRound && throughRound <= frontier && maxRecords <= 16, "fixture: bounds");
        result.start = _positionAt(afterRound);
        result.certifiedThroughRound = throughRound;
        RoundCheckpoint[] memory records = new RoundCheckpoint[](maxRecords);
        uint256 count;
        for (uint256 i; i < _records.length; ++i) {
            RoundCheckpoint memory checkpoint = _records[i];
            if (checkpoint.roundId <= afterRound) continue;
            if (checkpoint.roundId > throughRound) break;
            if (count == maxRecords) {
                result.certifiedThroughRound = checkpoint.roundId - 1;
                break;
            }
            records[count++] = checkpoint;
        }
        assembly ("memory-safe") {
            mstore(records, count)
        }
        result.rounds = records;
        result.end = _positionAt(result.certifiedThroughRound);
    }

    function _positionAt(uint64 round) private view returns (LedgerPosition memory result) {
        result.workPerThousandBlocks = 10_875;
        for (uint256 i = _records.length; i != 0; --i) {
            RoundCheckpoint memory checkpoint = _records[i - 1];
            if (checkpoint.roundId <= round) {
                return LedgerPosition(
                    checkpoint.cumulativeWork,
                    checkpoint.cumulativeBlockUnits,
                    checkpoint.workPerThousandBlocks
                );
            }
        }
    }
}
