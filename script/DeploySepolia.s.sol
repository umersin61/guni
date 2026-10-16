// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GUNI} from "../src/GUNI.sol";
import {IMorpho, Id, MarketParams, MarketParamsLib} from "../src/interfaces/IMorpho.sol";
import {MockUNI} from "../src/testnet/MockUNI.sol";
import {MockUSDC} from "../src/testnet/MockUSDC.sol";
import {FixedPriceOracle} from "../src/testnet/FixedPriceOracle.sol";

interface IMorphoFull is IMorpho {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
}

/// Sepolia deployment:
///   - MockUNI (faucet ERC20Votes), MockUSDC (faucet, 6 dec)
///   - FixedPriceOracle at $8.00 / UNI (settable, testnet only)
///   - GUNI(uni, morpho)  — no owner, exactly the mainnet contract
///   - Morpho Blue market gUNI/USDC, AdaptiveCurveIRM, 62.5% LLTV; registered on GUNI
///   - 50,000 USDC supplied by the deployer so borrowing works out of the box
contract DeploySepolia is Script {
    using MarketParamsLib for MarketParams;

    address constant MORPHO = 0xd011EE229E7459ba1ddd22631eF7bF528d424A14;
    address constant IRM = 0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c;
    uint256 constant LLTV = 0.625e18;
    // $8.00 per UNI: 8 * 1e36 * 1e6 / 1e18
    uint256 constant PRICE = 8 * 1e36 * 1e6 / 1e18;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        MockUNI uni = new MockUNI();
        MockUSDC usdc = new MockUSDC();
        FixedPriceOracle oracle = new FixedPriceOracle(PRICE);
        GUNI g = new GUNI(uni, IMorpho(MORPHO));

        MarketParams memory mp =
            MarketParams({loanToken: address(usdc), collateralToken: address(g), oracle: address(oracle), irm: IRM, lltv: LLTV});
        IMorphoFull(MORPHO).createMarket(mp);
        g.registerMarket(mp);

        usdc.mint(deployer, 50_000e6);
        usdc.approve(MORPHO, 50_000e6);
        IMorphoFull(MORPHO).supply(mp, 50_000e6, 0, deployer, "");

        vm.stopBroadcast();

        Id id = mp.id();
        string memory json = string.concat(
            '{\n  "chainId": 11155111,\n',
            '  "morpho": "', vm.toString(MORPHO), '",\n',
            '  "irm": "', vm.toString(IRM), '",\n',
            '  "uni": "', vm.toString(address(uni)), '",\n',
            '  "usdc": "', vm.toString(address(usdc)), '",\n',
            '  "oracle": "', vm.toString(address(oracle)), '",\n',
            '  "guni": "', vm.toString(address(g)), '",\n',
            '  "lltv": "', vm.toString(LLTV), '",\n',
            '  "marketId": "', vm.toString(Id.unwrap(id)), '",\n',
            '  "deployBlock": ', vm.toString(block.number), '\n}\n'
        );
        vm.writeFile("deployments/sepolia.json", json);
        console.log(json);
    }
}
