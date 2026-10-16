// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GUNI} from "../src/GUNI.sol";
import {IMorpho, Id, MarketParams, MarketParamsLib} from "../src/interfaces/IMorpho.sol";
import {MockUNI} from "../src/testnet/MockUNI.sol";
import {MockUSDC} from "../src/testnet/MockUSDC.sol";
import {FixedPriceOracle} from "../src/testnet/FixedPriceOracle.sol";

interface IMorphoFull is IMorpho {
    function borrow(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
}

/// End-to-end walk against the deployed contracts on the real Morpho Blue:
/// wrap → supply → borrow → redelegate mid-loan → repay → withdraw → unwrap,
/// then a second actor gets liquidated through the wrapper after a price drop.
/// Reads deployments/sepolia.json. Run with DEPLOYER_KEY set.
contract Scenario is Script {
    using MarketParamsLib for MarketParams;

    function run() external {
        string memory j = vm.readFile("deployments/sepolia.json");
        MockUNI uni = MockUNI(vm.parseJsonAddress(j, ".uni"));
        MockUSDC usdc = MockUSDC(vm.parseJsonAddress(j, ".usdc"));
        FixedPriceOracle oracle = FixedPriceOracle(vm.parseJsonAddress(j, ".oracle"));
        GUNI g = GUNI(vm.parseJsonAddress(j, ".guni"));
        IMorphoFull morpho = IMorphoFull(vm.parseJsonAddress(j, ".morpho"));
        MarketParams memory mp = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(g),
            oracle: address(oracle),
            irm: vm.parseJsonAddress(j, ".irm"),
            lltv: vm.parseJsonUint(j, ".lltv")
        });
        Id id = mp.id();

        uint256 pk = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(pk);
        _happyPath(uni, usdc, g, morpho, mp, id, vm.addr(pk));
        _liquidation(uni, usdc, oracle, g, morpho, mp, id, vm.addr(pk));
        vm.stopBroadcast();
    }

    address constant delegateA = 0x000000000000000000000000000000000000aaaa;
    address constant delegateB = 0x000000000000000000000000000000000000BbBB;

    function _happyPath(MockUNI uni, MockUSDC usdc, GUNI g, IMorphoFull morpho, MarketParams memory mp, Id id, address me) internal {

        // ── part 1: the happy path, me as depositor ──
        uni.mint(me, 1_000e18);
        uni.approve(address(g), type(uint256).max);
        g.approve(address(morpho), type(uint256).max);
        usdc.approve(address(morpho), type(uint256).max);

        g.wrap(1_000e18, delegateA);
        console.log("after wrap   votes A:", uni.getVotes(delegateA) / 1e18);

        morpho.supplyCollateral(mp, 600e18, me, "");
        morpho.borrow(mp, 2_000e6, 0, me, me);
        console.log("after borrow votes A:", uni.getVotes(delegateA) / 1e18, "collateral:", _coll(morpho, id, me) / 1e18);

        g.setDelegate(delegateB);
        console.log("redelegated  votes A:", uni.getVotes(delegateA) / 1e18, "votes B:", uni.getVotes(delegateB) / 1e18);

        usdc.mint(me, 100e6); // interest accrues between broadcast steps on a live chain
        morpho.repay(mp, 0, _shares(morpho, id, me), me, "");
        morpho.withdrawCollateral(mp, 600e18, me, me);
        g.unwrap(1_000e18, me);
        console.log("unwrapped    votes B:", uni.getVotes(delegateB) / 1e18, "UNI back:", uni.balanceOf(me) / 1e18);

    }

    function _liquidation(MockUNI uni, MockUSDC usdc, FixedPriceOracle oracle, GUNI g, IMorphoFull morpho, MarketParams memory mp, Id id, address me) internal {
        // ── part 2: liquidation through the wrapper ──
        // open a maximal position, then drop the oracle price and liquidate ourselves
        uni.approve(address(g), type(uint256).max);
        g.wrap(100e18); // delegate is now B
        morpho.supplyCollateral(mp, 100e18, me, "");
        // $8 * 100 * 0.625 = 500 max; borrow 490
        morpho.borrow(mp, 490e6, 0, me, me);
        uint256 p = oracle.price();
        oracle.setPrice(p * 70 / 100); // -30%: 560 * 0.625 = 350 < 490
        usdc.mint(me, 1_000e6);
        usdc.approve(address(g), type(uint256).max);
        (uint256 seized, uint256 repaid) = g.liquidate(mp, me, 40e18, 0);
        console.log("liquidated   seized UNI:", seized / 1e18, "repaid USDC:", repaid / 1e6);
        console.log("             votes B:", uni.getVotes(delegateB) / 1e18, "mirror:", g.collateralOf(id, me) / 1e18);
        oracle.setPrice(p);
        usdc.mint(me, 100e6);
        // close out
        morpho.repay(mp, 0, _shares(morpho, id, me), me, "");
        morpho.withdrawCollateral(mp, _coll(morpho, id, me), me, me);
        g.unwrap(g.balanceOf(me), me);
        console.log("closed       gUNI supply:", g.totalSupply(), "votes B:", uni.getVotes(delegateB));
    }

    function _coll(IMorpho m, Id id, address who) internal view returns (uint256 c) {
        (,, uint128 cc) = m.position(id, who);
        c = cc;
    }

    function _shares(IMorpho m, Id id, address who) internal view returns (uint256 s) {
        (, uint128 ss,) = m.position(id, who);
        s = ss;
    }
}
