// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Testnet-only Morpho oracle. Returns the price of one unit of collateral
///         in loan-token units, scaled per Morpho Blue: 1e36 * 10**loanDecimals / 10**collateralDecimals.
///         A settable price lets testers push positions underwater to exercise liquidation.
///         On mainnet gUNI/USD is UNI/USD 1:1 and would use a Chainlink-based MorphoChainlinkOracleV2.
contract FixedPriceOracle {
    address public immutable OWNER;
    uint256 public price;

    event PriceSet(uint256 price);

    error NotOwner();

    constructor(uint256 initialPrice) {
        OWNER = msg.sender;
        price = initialPrice;
        emit PriceSet(initialPrice);
    }

    function setPrice(uint256 p) external {
        if (msg.sender != OWNER) revert NotOwner();
        price = p;
        emit PriceSet(p);
    }
}
