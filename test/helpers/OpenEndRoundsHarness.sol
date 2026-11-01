// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OpenEndRounds} from "../../src/OpenEndRounds.sol";

/// @dev Exposes the internal library for differential fuzzing against a naive minimum.
contract OpenEndRoundsHarness {
    using OpenEndRounds for OpenEndRounds.Set;

    OpenEndRounds.Set private _set;

    function add(uint64 end) external {
        _set.add(end);
    }

    function remove(uint64 end) external {
        _set.remove(end);
    }

    function earliest() external view returns (uint64) {
        return _set.earliest;
    }

    function count() external view returns (uint256) {
        return _set.count;
    }

    function countByEnd(uint64 end) external view returns (uint256) {
        return _set.countByEnd[end];
    }
}
