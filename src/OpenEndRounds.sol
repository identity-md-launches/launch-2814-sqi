// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Multiset of the end rounds of open policies with an O(1) earliest-end query.
/// @dev Two-level bitmap over end rounds: `words[e >> 8]` holds bit `e & 255`, and `summary[w >> 8]`
/// holds bit `w & 255` for every nonempty word `w`. Insertion and removal touch a constant number of
/// slots; recomputing the earliest end after its bucket empties skips empty words through the summary.
/// All functions are internal so the compiler inlines them into the calling contract.
library OpenEndRounds {
    struct Set {
        uint256 count;
        uint64 earliest;
        mapping(uint64 end => uint256 open) countByEnd;
        mapping(uint256 word => uint256 bits) words;
        mapping(uint256 word => uint256 bits) summary;
    }

    function add(Set storage self, uint64 end) internal {
        if (self.countByEnd[end]++ == 0) {
            uint256 word = uint256(end) >> 8;
            uint256 bits = self.words[word];
            if (bits == 0) self.summary[word >> 8] |= uint256(1) << (word & 255);
            self.words[word] = bits | (uint256(1) << (end & 255));
        }
        if (self.count == 0 || end < self.earliest) self.earliest = end;
        ++self.count;
    }

    function remove(Set storage self, uint64 end) internal {
        uint256 remaining = --self.countByEnd[end];
        --self.count;
        if (remaining != 0) return;
        uint256 word = uint256(end) >> 8;
        uint256 bits = self.words[word] & ~(uint256(1) << (end & 255));
        self.words[word] = bits;
        if (bits == 0) self.summary[word >> 8] &= ~(uint256(1) << (word & 255));
        if (end == self.earliest) {
            self.earliest = self.count == 0 ? 0 : _nextFrom(self, uint256(end) + 1);
        }
    }

    /// @dev Smallest populated end round >= `from`. Requires that one exists (count > 0 after removing
    /// the previous earliest guarantees it, because every other open end is larger).
    function _nextFrom(Set storage self, uint256 from) private view returns (uint64) {
        uint256 word = from >> 8;
        uint256 bits = self.words[word] & (type(uint256).max << (from & 255));
        if (bits == 0) {
            uint256 probe = word + 1;
            while (true) {
                uint256 summaryWord = probe >> 8;
                uint256 summaryBits = self.summary[summaryWord] & (type(uint256).max << (probe & 255));
                if (summaryBits != 0) {
                    word = (summaryWord << 8) | _lowestBit(summaryBits);
                    break;
                }
                probe = (summaryWord + 1) << 8;
            }
            bits = self.words[word];
        }
        return uint64((word << 8) | _lowestBit(bits));
    }

    function _lowestBit(uint256 value) private pure returns (uint256) {
        return Math.log2(value & (~value + 1));
    }
}
