// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Managed} from "./Managed.sol";

/// @notice Sepolia mock collateral, called mSQK in the cover specification. It is not real SQK.
/// @dev Explicit token metadata follows the request: SQI / SQI, 18 decimals.
contract MockSQK is ERC20, Managed {
    uint256 public constant INITIAL_SUPPLY = 100_000_000 ether;

    constructor(address owner_) ERC20("SQI", "SQI") Managed(owner_) {
        _mint(owner_, INITIAL_SUPPLY);
    }

    /// @notice Owner faucet. The requested supply is initial supply, not an immutable cap.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
