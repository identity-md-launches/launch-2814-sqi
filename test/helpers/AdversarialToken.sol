// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token. The launch uses the fixed standard MockSQK, never this contract.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Fee,
        NoReturn,
        Callback
    }

    Mode public mode;
    address public fromFilter;
    address public target;
    bytes public callData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Adversarial fixture", "FIXTURE") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configure(Mode mode_, address from_, address target_, bytes calldata data_) external {
        mode = mode_;
        fromFilter = from_;
        target = target_;
        callData = data_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (_applies(msg.sender) && mode == Mode.ReturnFalse) return false;
        super.transfer(to, amount);
        _afterTransfer(msg.sender, to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_applies(from) && mode == Mode.ReturnFalse) return false;
        super.transferFrom(from, to, amount);
        _afterTransfer(from, to);
        return true;
    }

    function _applies(address from) private view returns (bool) {
        return fromFilter == address(0) || fromFilter == from;
    }

    function _afterTransfer(address from, address to) private {
        if (!_applies(from)) return;
        if (mode == Mode.Fee) _burn(to, 1);
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == Mode.Callback) (callbackSucceeded, callbackResult) = target.call(callData);
    }
}
