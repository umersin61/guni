// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal loan token with an open faucet, capped per call.
contract MockUSDC is ERC20 {
    uint256 public constant FAUCET_CAP = 100_000e6;

    error FaucetCap();

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (amount > FAUCET_CAP) revert FaucetCap();
        _mint(to, amount);
    }
}
