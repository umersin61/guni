// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, IMorphoLiquidateCallback, Id, MarketParams, MarketParamsLib} from "../../src/interfaces/IMorpho.sol";

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @notice Minimal Morpho Blue stand-in. What matters for gUNI is reproduced faithfully:
///   * position is updated BEFORE the collateral token transfer in
///     supplyCollateral / withdrawCollateral / liquidate
///   * liquidate transfers collateral to msg.sender, then calls
///     onMorphoLiquidate (if data.length > 0), then pulls the loan token from msg.sender
///   * flashLoan transfers out, calls back, pulls back
/// Shares == assets, no interest, no incentive. Price is settable (1e18 = 1:1) so tests
/// can push positions underwater. Health is collateral * price * lltv >= debt.
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    struct Pos {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Mkt {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    mapping(Id => mapping(address => Pos)) internal _position;
    mapping(Id => Mkt) internal _market;
    mapping(Id => MarketParams) public params;
    /// collateral units → loan units, 1e18 scaled
    uint256 public price = 1e18;

    function setPrice(uint256 p) external {
        price = p;
    }

    function position(Id id, address user) external view returns (uint256, uint128, uint128) {
        Pos storage p = _position[id][user];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Mkt storage m = _market[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function createMarket(MarketParams memory mp) external returns (Id id) {
        id = mp.id();
        require(_market[id].lastUpdate == 0, "exists");
        _market[id].lastUpdate = uint128(block.timestamp);
        params[id] = mp;
    }

    function supply(MarketParams memory mp, uint256 assets) external {
        Id id = mp.id();
        _position[id][msg.sender].supplyShares += assets;
        _market[id].totalSupplyAssets += uint128(assets);
        _market[id].totalSupplyShares += uint128(assets);
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes memory) external {
        Id id = mp.id();
        require(_market[id].lastUpdate != 0, "no market");
        require(assets != 0, "zero");
        _position[id][onBehalf].collateral += uint128(assets);
        IERC20(mp.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        Id id = mp.id();
        require(onBehalf == msg.sender, "unauthorized"); // no authorization mocks
        _position[id][onBehalf].collateral -= uint128(assets);
        require(_healthy(id, onBehalf), "unhealthy");
        IERC20(mp.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        Id id = mp.id();
        require(onBehalf == msg.sender, "unauthorized");
        _position[id][onBehalf].borrowShares += uint128(assets);
        _market[id].totalBorrowAssets += uint128(assets);
        _market[id].totalBorrowShares += uint128(assets);
        require(_healthy(id, onBehalf), "unhealthy");
        IERC20(mp.loanToken).safeTransfer(receiver, assets);
    }

    function repay(MarketParams memory mp, uint256 assets, address onBehalf) external {
        Id id = mp.id();
        _position[id][onBehalf].borrowShares -= uint128(assets);
        _market[id].totalBorrowAssets -= uint128(assets);
        _market[id].totalBorrowShares -= uint128(assets);
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function liquidate(MarketParams memory mp, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external
        returns (uint256, uint256)
    {
        Id id = mp.id();
        require(!_healthy(id, borrower), "healthy");
        require((seizedAssets == 0) != (repaidShares == 0), "inconsistent");
        uint256 repaid;
        if (seizedAssets > 0) {
            repaid = seizedAssets * price / 1e18;
        } else {
            repaid = repaidShares;
            seizedAssets = repaid * 1e18 / price;
        }
        Pos storage p = _position[id][borrower];
        p.collateral -= uint128(seizedAssets);
        p.borrowShares -= uint128(repaid);
        _market[id].totalBorrowAssets -= uint128(repaid);
        _market[id].totalBorrowShares -= uint128(repaid);
        // state updated — now the transfers, in Morpho Blue's order
        IERC20(mp.collateralToken).safeTransfer(msg.sender, seizedAssets);
        if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaid, data);
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), repaid);
        return (seizedAssets, repaid);
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    function _healthy(Id id, address user) internal view returns (bool) {
        Pos storage p = _position[id][user];
        if (p.borrowShares == 0) return true;
        uint256 maxBorrow = uint256(p.collateral) * price / 1e18 * params[id].lltv / 1e18;
        return maxBorrow >= p.borrowShares;
    }
}
