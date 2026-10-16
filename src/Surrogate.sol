// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @notice Holds UNI on behalf of the wrapper and delegates it, once and forever,
///         to a single delegatee. One surrogate per delegatee, deployed by the wrapper
///         with CREATE2 so its address is deterministic.
contract Surrogate {
    using SafeERC20 for IERC20;

    address public immutable WRAPPER;
    IERC20 public immutable TOKEN;
    address public immutable DELEGATEE;

    error NotWrapper();

    constructor(IERC20 token, address delegatee) {
        WRAPPER = msg.sender;
        TOKEN = token;
        DELEGATEE = delegatee;
        // Uni.sol (Comp-style) and OZ ERC20Votes share the delegate(address) selector.
        IVotes(address(token)).delegate(delegatee);
    }

    /// @dev Only the wrapper can move tokens out. There is no other function.
    function transfer(address to, uint256 amount) external {
        if (msg.sender != WRAPPER) revert NotWrapper();
        TOKEN.safeTransfer(to, amount);
    }
}
