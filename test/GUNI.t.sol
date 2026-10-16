// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GUNI} from "../src/GUNI.sol";
import {Surrogate} from "../src/Surrogate.sol";
import {Id, MarketParams, MarketParamsLib} from "../src/interfaces/IMorpho.sol";
import {MockUNI} from "../src/testnet/MockUNI.sol";
import {MockUSDC} from "../src/testnet/MockUSDC.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FlashBorrower {
    MockMorpho immutable morpho;

    constructor(MockMorpho m) {
        morpho = m;
    }

    function go(address token, uint256 amt) external {
        morpho.flashLoan(token, amt, "");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        // would do something with the borrowed gUNI here; the hook never lets us get this far
        assets;
    }
}

contract GUNITest is Test {
    using MarketParamsLib for MarketParams;

    MockUNI uni;
    MockUSDC usdc;
    MockMorpho morpho;
    GUNI g;
    MarketParams mp;
    Id id;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dA = makeAddr("delegateA");
    address dB = makeAddr("delegateB");
    address lender = makeAddr("lender");
    address liq = makeAddr("liquidator");

    uint256 constant PRICE = 1e6; // 1 UNI = 1 USDC in the mock

    function setUp() public {
        uni = new MockUNI();
        usdc = new MockUSDC();
        morpho = new MockMorpho();
        morpho.setPrice(PRICE);
        g = new GUNI(uni, morpho);
        mp = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(g),
            oracle: address(0),
            irm: address(0),
            lltv: 0.625e18
        });
        id = morpho.createMarket(mp);
        g.registerMarket(mp);

        // lender seeds the market
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(morpho), type(uint256).max);
        morpho.supply(mp, 100_000e6);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            address a = [alice, bob, carol][i];
            uni.mint(a, 1_000e18);
            vm.startPrank(a);
            uni.approve(address(g), type(uint256).max);
            g.approve(address(morpho), type(uint256).max);
            usdc.approve(address(morpho), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _votes(address d) internal view returns (uint256) {
        return uni.getVotes(d);
    }

    function _coll(address who) internal view returns (uint256 c) {
        (,, uint128 cc) = morpho.position(id, who);
        c = cc;
    }

    // ───────────────────────────── wrap / unwrap ─────────────────────────────

    function test_wrapDefaultsDelegateToSelf() public {
        vm.prank(alice);
        g.wrap(100e18);
        assertEq(g.balanceOf(alice), 100e18);
        assertEq(g.delegateOf(alice), alice);
        assertEq(_votes(alice), 100e18);
        assertEq(uni.balanceOf(address(g)), 0, "wrapper holds no UNI");
    }

    function test_wrapWithDelegate() public {
        vm.prank(alice);
        g.wrap(100e18, dA);
        assertEq(g.delegateOf(alice), dA);
        assertEq(_votes(dA), 100e18);
        assertEq(g.votesVia(dA), 100e18);
    }

    function test_wrapMismatchReverts() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        vm.expectRevert(abi.encodeWithSelector(GUNI.DelegateMismatch.selector, dA));
        g.wrap(1e18, dB);
        vm.stopPrank();
    }

    function test_unwrapReturnsUNIAndVotes() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        g.unwrap(40e18, alice);
        vm.stopPrank();
        assertEq(g.balanceOf(alice), 60e18);
        assertEq(uni.balanceOf(alice), 940e18);
        assertEq(_votes(dA), 60e18);
    }

    function test_surrogateIsDeterministic() public {
        vm.prank(alice);
        g.wrap(1e18, dA);
        Surrogate s = g.surrogateOf(dA);
        bytes32 initHash = keccak256(abi.encodePacked(type(Surrogate).creationCode, abi.encode(uni, dA)));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(g), bytes32(uint256(uint160(dA))), initHash))))
        );
        assertEq(address(s), predicted);
        assertEq(s.DELEGATEE(), dA);
        vm.expectRevert(Surrogate.NotWrapper.selector);
        s.transfer(alice, 1);
    }

    // ───────────────────────────── transfers ─────────────────────────────

    function test_transferToFreshReceiverInheritsDelegate() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        g.transfer(bob, 30e18);
        vm.stopPrank();
        assertEq(g.delegateOf(bob), dA);
        assertEq(_votes(dA), 100e18);
    }

    function test_transferToDifferentDelegateMovesUNI() public {
        vm.prank(alice);
        g.wrap(100e18, dA);
        vm.prank(bob);
        g.wrap(10e18, dB);
        vm.prank(alice);
        g.transfer(bob, 30e18);
        assertEq(_votes(dA), 70e18);
        assertEq(_votes(dB), 40e18);
    }

    function test_setDelegateMovesWallet() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        g.setDelegate(dB);
        vm.stopPrank();
        assertEq(_votes(dA), 0);
        assertEq(_votes(dB), 100e18);
    }

    function test_setDelegateBeforeAnyBalance() public {
        vm.prank(alice);
        g.setDelegate(dB);
        assertEq(g.delegateOf(alice), dB);
        vm.prank(alice);
        g.wrap(10e18);
        assertEq(_votes(dB), 10e18);
    }

    function test_directTransferToWrapperReverts() public {
        vm.startPrank(alice);
        g.wrap(10e18);
        vm.expectRevert(GUNI.DirectTransferToWrapper.selector);
        g.transfer(address(g), 1e18);
        vm.stopPrank();
    }

    // ───────────────────────────── Morpho: supply / withdraw ─────────────────────────────

    function test_selfSupplyKeepsVotes() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 60e18, alice, "");
        vm.stopPrank();
        assertEq(_coll(alice), 60e18);
        assertEq(g.collateralOf(id, alice), 60e18);
        assertEq(g.balanceOf(alice), 40e18);
        assertEq(_votes(dA), 100e18, "votes unchanged while posted");
    }

    function test_selfWithdrawKeepsVotes() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 60e18, alice, "");
        morpho.withdrawCollateral(mp, 25e18, alice, alice);
        vm.stopPrank();
        assertEq(_coll(alice), 35e18);
        assertEq(g.collateralOf(id, alice), 35e18);
        assertEq(g.balanceOf(alice), 65e18);
        assertEq(_votes(dA), 100e18);
    }

    function test_borrowAndRepayUnaffected() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 100e18, alice, "");
        morpho.borrow(mp, 50e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 50e6);
        morpho.repay(mp, 50e6, alice);
        vm.stopPrank();
        assertEq(_votes(dA), 100e18);
    }

    function test_setDelegateMidLoanMovesCollateralToo() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 70e18, alice, "");
        morpho.borrow(mp, 30e6, alice, alice);
        g.setDelegate(dB);
        vm.stopPrank();
        assertEq(_votes(dA), 0);
        assertEq(_votes(dB), 100e18, "wallet 30 + collateral 70");
        assertEq(_coll(alice), 70e18, "Morpho untouched");
    }

    function test_supplyOnBehalfOfOtherReverts() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        vm.expectRevert(GUNI.NotAttributable.selector);
        morpho.supplyCollateral(mp, 10e18, bob, "");
        vm.stopPrank();
    }

    function test_withdrawToThirdPartyReverts() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 60e18, alice, "");
        vm.expectRevert(GUNI.NotAttributable.selector);
        morpho.withdrawCollateral(mp, 10e18, alice, bob);
        vm.stopPrank();
    }

    function test_flashLoanOfGUNIReverts() public {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 100e18, alice, "");
        vm.stopPrank();
        FlashBorrower fb = new FlashBorrower(morpho);
        vm.expectRevert(GUNI.NotAttributable.selector);
        fb.go(address(g), 1e18);
    }

    // ───────────────────────────── liquidation ─────────────────────────────

    function _underwater() internal {
        vm.startPrank(alice);
        g.wrap(100e18, dA);
        morpho.supplyCollateral(mp, 100e18, alice, "");
        morpho.borrow(mp, 60e6, alice, alice);
        vm.stopPrank();
        morpho.setPrice(0.8e6); // 100 UNI now worth 80 USDC; 80*0.625 = 50 < 60 debt
        usdc.mint(liq, 100_000e6);
        vm.prank(liq);
        usdc.approve(address(g), type(uint256).max);
    }

    function test_liquidateViaWrapperIsExact() public {
        _underwater();
        vm.prank(liq);
        (uint256 seized, uint256 repaid) = g.liquidate(mp, alice, 50e18, 0);
        assertEq(seized, 50e18);
        assertEq(repaid, 40e6);
        assertEq(uni.balanceOf(liq), 50e18, "liquidator paid in plain UNI");
        assertEq(usdc.balanceOf(liq), 100_000e6 - 40e6);
        assertEq(_coll(alice), 50e18);
        assertEq(g.collateralOf(id, alice), 50e18);
        assertEq(_votes(dA), 50e18, "only the seized amount left the delegate");
        assertEq(g.totalSupply(), 50e18);
        assertEq(g.balanceOf(address(g)), 0);
    }

    function test_directMorphoLiquidateReverts() public {
        _underwater();
        vm.startPrank(liq);
        usdc.approve(address(morpho), type(uint256).max);
        vm.expectRevert(GUNI.NotAttributable.selector);
        morpho.liquidate(mp, alice, 50e18, 0, "");
        vm.stopPrank();
    }

    function test_liquidateUnregisteredMarketReverts() public {
        MarketParams memory other = mp;
        other.lltv = 0.77e18;
        vm.expectRevert(GUNI.MarketNotRegistered.selector);
        g.liquidate(other, alice, 1, 0);
    }

    function test_onMorphoLiquidateGuards() public {
        vm.expectRevert(GUNI.NotMorpho.selector);
        g.onMorphoLiquidate(1, abi.encode(address(usdc)));
        vm.prank(address(morpho));
        vm.expectRevert(GUNI.NoContext.selector);
        g.onMorphoLiquidate(1, abi.encode(address(usdc)));
    }

    // ───────────────────────────── registry ─────────────────────────────

    function test_registerRefusesGovernanceLoanToken() public {
        MarketParams memory bad = mp;
        bad.loanToken = address(uni);
        morpho.createMarket(bad);
        vm.expectRevert(GUNI.MarketLoansGovernanceToken.selector);
        g.registerMarket(bad);
        bad.loanToken = address(g);
        vm.expectRevert(GUNI.MarketLoansGovernanceToken.selector);
        g.registerMarket(bad);
    }

    function test_registerChecks() public {
        MarketParams memory bad = mp;
        bad.collateralToken = address(uni);
        vm.expectRevert(GUNI.MarketNotForThisToken.selector);
        g.registerMarket(bad);

        vm.expectRevert(GUNI.MarketAlreadyRegistered.selector);
        g.registerMarket(mp);

        MarketParams memory uncreated = mp;
        uncreated.lltv = 0.77e18;
        vm.expectRevert(GUNI.MarketNotCreated.selector);
        g.registerMarket(uncreated);
        assertEq(g.marketCount(), 1);
    }

    // ───────────────────────────── invariant fuzz ─────────────────────────────

    /// After every random wrap / supply / withdraw / transfer / redelegate:
    ///   * each delegate's getVotes == sum over holders pointing at it of wallet + collateral
    ///   * total UNI in surrogates == gUNI totalSupply
    function testFuzz_votesAlwaysEqualHoldings(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        address[3] memory dels = [dA, dB, carol];
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address u = users[r % 3];
            uint256 op = (r >> 8) % 5;
            uint256 amt = ((r >> 16) % 50 + 1) * 1e18;
            vm.startPrank(u);
            if (op == 0) {
                if (uni.balanceOf(u) >= amt) {
                    if (g.delegateOf(u) == address(0)) g.wrap(amt, dels[(r >> 40) % 3]);
                    else g.wrap(amt);
                }
            } else if (op == 1) {
                if (g.balanceOf(u) >= amt) morpho.supplyCollateral(mp, amt, u, "");
            } else if (op == 2) {
                if (_coll(u) >= amt) morpho.withdrawCollateral(mp, amt, u, u);
            } else if (op == 3) {
                address to = users[(r >> 48) % 3];
                if (to != u && g.balanceOf(u) >= amt) g.transfer(to, amt);
            } else {
                address nd = dels[(r >> 56) % 3];
                if (g.delegateOf(u) != nd) g.setDelegate(nd);
            }
            vm.stopPrank();
            _checkInvariant(users, dels);
        }
    }

    function _checkInvariant(address[3] memory users, address[3] memory dels) internal view {
        uint256 surrogateTotal;
        for (uint256 i; i < 3; ++i) {
            address d = dels[i];
            uint256 expected;
            for (uint256 j; j < 3; ++j) {
                if (g.delegateOf(users[j]) == d) expected += g.balanceOf(users[j]) + g.collateralOf(id, users[j]);
            }
            // carol is both a user and a delegate; her bare UNI is undelegated so carries no votes
            assertEq(uni.getVotes(d), expected, "votes != holdings");
            surrogateTotal += g.votesVia(d);
        }
        assertEq(surrogateTotal, g.totalSupply(), "surrogate UNI != supply");
    }
}
