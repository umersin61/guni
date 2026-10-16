// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GUNI} from "../src/GUNI.sol";
import {IMorpho, Id, MarketParams, MarketParamsLib} from "../src/interfaces/IMorpho.sol";
import {MockUSDC} from "../src/testnet/MockUSDC.sol";
import {FixedPriceOracle} from "../src/testnet/FixedPriceOracle.sol";

interface IMorphoFull is IMorpho {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
}

/// Deploys a fresh (permissionless) oracle and a new gUNI/USDC market against the EXISTING gUNI,
/// registers it, seeds USDC, and rewrites deployments/sepolia.json to point at the new market.
contract NewMarket is Script {
    using MarketParamsLib for MarketParams;

    uint256 constant PRICE = 8 * 1e36 * 1e6 / 1e18;

    function run() external {
        string memory j = vm.readFile("deployments/sepolia.json");
        address morpho = vm.parseJsonAddress(j, ".morpho");
        address irm = vm.parseJsonAddress(j, ".irm");
        address uni = vm.parseJsonAddress(j, ".uni");
        MockUSDC usdc = MockUSDC(vm.parseJsonAddress(j, ".usdc"));
        GUNI g = GUNI(vm.parseJsonAddress(j, ".guni"));
        uint256 lltv = vm.parseJsonUint(j, ".lltv");
        uint256 deployBlock = vm.parseJsonUint(j, ".deployBlock");

        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        FixedPriceOracle oracle = new FixedPriceOracle(PRICE);
        MarketParams memory mp =
            MarketParams({loanToken: address(usdc), collateralToken: address(g), oracle: address(oracle), irm: irm, lltv: lltv});
        IMorphoFull(morpho).createMarket(mp);
        g.registerMarket(mp);
        usdc.mint(deployer, 50_000e6);
        usdc.approve(morpho, 50_000e6);
        IMorphoFull(morpho).supply(mp, 50_000e6, 0, deployer, "");
        vm.stopBroadcast();

        string memory out = string.concat(
            '{\n  "chainId": 11155111,\n',
            '  "morpho": "', vm.toString(morpho), '",\n',
            '  "irm": "', vm.toString(irm), '",\n',
            '  "uni": "', vm.toString(uni), '",\n',
            '  "usdc": "', vm.toString(address(usdc)), '",\n',
            '  "oracle": "', vm.toString(address(oracle)), '",\n',
            '  "guni": "', vm.toString(address(g)), '",\n',
            '  "lltv": "', vm.toString(lltv), '",\n',
            '  "marketId": "', vm.toString(Id.unwrap(mp.id())), '",\n',
            '  "deployBlock": ', vm.toString(deployBlock), '\n}\n'
        );
        vm.writeFile("deployments/sepolia.json", out);
        console.log(out);
    }
}
