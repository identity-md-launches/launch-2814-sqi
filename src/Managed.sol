// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Explicit owner argument: the launch factory is the constructor caller and must never become owner.
abstract contract Managed is Ownable2Step {
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    /// @dev Retain the owner needed to configure prices, activate the book and manage pauses.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
