# gUNI — governance-enabled UNI for Morpho Blue

A 1:1 wrapper around UNI that keeps voting for each holder's chosen delegate even while
posted as collateral on Morpho Blue. No owner, no whitelist, no upgrade, no fee.

Three ideas, each small:

- **Surrogates.** One minimal contract per delegate (CREATE2), holds UNI and calls
  `UNI.delegate(delegatee)` once. The wrapper itself never holds UNI.
- **One delegate per holder.** `delegateOf[holder]`; set at first wrap (defaults to self),
  inherited on first receipt, changed with `setDelegate`, which moves wallet *and* collateral
  in one UNI transfer without touching Morpho.
- **Morpho position mirror.** Morpho Blue updates `position()` before it transfers tokens, so
  the ERC-20 transfer hook can verify every Morpho-side transfer against Morpho's own state.
  Self-supply and self-withdraw work directly on Morpho; liquidations go through
  `gUNI.liquidate` and pay the liquidator in plain UNI; everything else reverts.

Design write-up: *Introducing gUnits* (Api3, October 2026).

## Layout

```
src/GUNI.sol                 the wrapper
src/Surrogate.sol            one per delegate
src/interfaces/IMorpho.sol   minimal Morpho Blue interface
src/testnet/                 faucet UNI (ERC20Votes), faucet USDC, settable oracle — Sepolia only
test/GUNI.t.sol              24 tests incl. a 256-run invariant fuzz
test/mocks/MockMorpho.sol    reproduces Morpho's state-before-transfer ordering
script/DeploySepolia.s.sol   deploys everything and creates + registers the Morpho market
script/Scenario.s.sol        on-chain walk-through: wrap → borrow → redelegate → liquidate → close
script/build-frontend.sh     inlines deployments/sepolia.json into the frontend
frontend/index.template.html single-file dApp (ethers v6)
deployments/sepolia.json     live addresses
```

## Build and test

```sh
forge install OpenZeppelin/openzeppelin-contracts@v5.2.0 foundry-rs/forge-std
forge test
```

Solidity 0.8.28, Cancun EVM (transient storage), OpenZeppelin 5.2.0.

## Deploy to Sepolia

Morpho Blue on Sepolia: `0xd011EE229E7459ba1ddd22631eF7bF528d424A14` ·
AdaptiveCurveIRM: `0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c` · LLTV 62.5 %.

```sh
export DEPLOYER_KEY=0x…   # funded on Sepolia
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
forge script script/DeploySepolia.s.sol --rpc-url sepolia --broadcast --verify   # --verify needs ETHERSCAN_API_KEY
./script/build-frontend.sh
forge script script/Scenario.s.sol --rpc-url sepolia --broadcast   # optional end-to-end check
```

The deploy also supplies 50,000 test USDC to the market so borrowing works immediately.

## Frontend

`frontend/index.html` is a single static file. Open it from any static host (or
`npx serve frontend`), connect a wallet on Sepolia, mint test tokens from the faucets, wrap,
supply, borrow, re-delegate. The right rail shows your position, health, and how much UNI each
delegate's surrogate is voting with.

## Before mainnet

Fork test against the real Uni token (Comp-style `delegate`, same selector) and Morpho Blue;
Chainlink-based oracle (gUNI/USD = UNI/USD, 1:1); optional liquidator callback for flash-repay
bots; audit focused on the hook never reverting for a legitimate transfer and on the
transient-context lifecycle.
