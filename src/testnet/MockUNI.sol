// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @notice Stand-in for the real Uni token. The real one is Comp-style rather than
///         OZ ERC20Votes, but `delegate(address)` has the same selector, which is the
///         only call the Surrogate makes. Anyone may mint (testnet faucet), capped per call.
contract MockUNI is ERC20, ERC20Permit, ERC20Votes {
    uint256 public constant FAUCET_CAP = 10_000e18;

    error FaucetCap();

    constructor() ERC20("Uniswap", "UNI") ERC20Permit("Uniswap") {}

    function mint(address to, uint256 amount) external {
        if (amount > FAUCET_CAP) revert FaucetCap();
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
