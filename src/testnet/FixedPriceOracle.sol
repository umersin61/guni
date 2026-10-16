// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Testnet-only Morpho oracle. Anyone can set the price.
///         Returns the price of one unit of collateral in loan-token units, scaled per Morpho Blue:
///         1e36 * 10**loanDecimals / 10**collateralDecimals (for gUNI/USDC: 8 USDC = 8e24).
///         Move it to push positions underwater and exercise liquidation.
///         On mainnet gUNI/USD is UNI/USD 1:1 and would use a Chainlink-based MorphoChainlinkOracleV2.
contract FixedPriceOracle {
    uint256 public price;

    event PriceSet(address indexed by, uint256 price);

    error ZeroPrice();

    constructor(uint256 initialPrice) {
        price = initialPrice;
        emit PriceSet(msg.sender, initialPrice);
    }

    function setPrice(uint256 p) external {
        if (p == 0) revert ZeroPrice();
        price = p;
        emit PriceSet(msg.sender, p);
    }
}
