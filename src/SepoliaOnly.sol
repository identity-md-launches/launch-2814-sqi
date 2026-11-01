// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev All five application contracts are testnet-only, including deployment rehearsals.
abstract contract SepoliaOnly {
    error WrongChain(uint256 chainId);

    constructor() {
        if (block.chainid != 11_155_111) revert WrongChain(block.chainid);
    }
}
