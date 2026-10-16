// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, IMorphoLiquidateCallback, Id, MarketParams, MarketParamsLib} from "./interfaces/IMorpho.sol";
import {Surrogate} from "./Surrogate.sol";

/// @title gUNI — governance-enabled UNI wrapper for Morpho Blue
///
/// @notice One ERC20, 1:1 with UNI, permissionless wrap/unwrap, no owner.
///         Every holder has exactly one delegate. The UNI backing a holder's
///         balance lives in a per-delegate Surrogate that has called
///         `UNI.delegate(delegatee)`, so it votes for that delegate.
///
///         gUNI posted as collateral on a registered Morpho Blue market keeps
///         voting for the depositor's delegate. The wrapper mirrors each
///         borrower's collateral per market and verifies every Morpho-side
///         transfer against Morpho's own `position()` so attribution is exact:
///
///           - supplyCollateral for yourself  → works directly on Morpho
///           - withdrawCollateral to yourself → works directly on Morpho
///           - liquidation                    → must go through `liquidate()` here
///           - anything else (bundlers, onBehalf ≠ sender, receiver ≠ onBehalf,
///             flash loans of gUNI)            → reverts
///
///         Votes are never created or destroyed: 1 UNI wrapped = 1 vote, always.
contract GUNI is ERC20, IMorphoLiquidateCallback {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    // ───────────────────────────── immutables ─────────────────────────────

    IERC20 public immutable UNI;
    IMorpho public immutable MORPHO;
    uint256 public constant MAX_MARKETS = 8;

    // ─────────────────────────────── storage ──────────────────────────────

    /// @notice The single delegate for each holder. address(0) = never set.
    mapping(address => address) public delegateOf;

    /// @notice delegatee → its Surrogate (address(0) until first use).
    mapping(address => Surrogate) public surrogateOf;

    /// @notice Registered Morpho markets whose collateral token is gUNI.
    Id[] public markets;
    mapping(Id => bool) public isRegistered;

    /// @notice Mirror of Morpho's `position(id, borrower).collateral`.
    mapping(Id => mapping(address => uint256)) public collateralOf;

    // ───────────────────────── transient (per-tx) ─────────────────────────

    bool private transient _ctxActive;
    bytes32 private transient _ctxId;
    address private transient _ctxBorrower;
    address private transient _ctxLiquidator;
    address private transient _ctxTransitDelegate;

    // ─────────────────────────────── events ───────────────────────────────

    event DelegateSet(address indexed holder, address indexed delegatee);
    event SurrogateDeployed(address indexed delegatee, address surrogate);
    event MarketRegistered(Id indexed id, address loanToken);
    event Wrapped(address indexed holder, uint256 amount);
    event Unwrapped(address indexed holder, address indexed to, uint256 amount);
    event Liquidated(Id indexed id, address indexed borrower, address indexed liquidator, uint256 seized, uint256 repaid);

    // ─────────────────────────────── errors ───────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error DelegateMismatch(address current);
    error SameDelegate();
    error NotAttributable();
    error NotMorpho();
    error NoContext();
    error ContextActive();
    error DirectTransferToWrapper();
    error MarketNotForThisToken();
    error MarketLoansGovernanceToken();
    error MarketNotCreated();
    error MarketAlreadyRegistered();
    error TooManyMarkets();
    error MarketNotRegistered();

    // ───────────────────────────── constructor ────────────────────────────

    constructor(IERC20 uni, IMorpho morpho) ERC20("Governance-enabled UNI", "gUNI") {
        if (address(uni) == address(0) || address(morpho) == address(0)) revert ZeroAddress();
        UNI = uni;
        MORPHO = morpho;
    }

    // ──────────────────────────── wrap / unwrap ───────────────────────────

    /// @notice Wrap UNI using your existing delegate (or yourself, if none).
    function wrap(uint256 amount) external {
        wrap(amount, address(0));
    }

    /// @notice Wrap UNI and point its vote at `delegatee`.
    /// @dev If you already have a delegate, `delegatee` must be address(0) or match it.
    ///      Use `setDelegate` to change.
    function wrap(uint256 amount, address delegatee) public {
        if (amount == 0) revert ZeroAmount();
        address current = delegateOf[msg.sender];
        if (current == address(0)) {
            current = delegatee == address(0) ? msg.sender : delegatee;
            delegateOf[msg.sender] = current;
            emit DelegateSet(msg.sender, current);
        } else if (delegatee != address(0) && delegatee != current) {
            revert DelegateMismatch(current);
        }
        UNI.safeTransferFrom(msg.sender, address(_surrogate(current)), amount);
        _mint(msg.sender, amount);
        emit Wrapped(msg.sender, amount);
    }

    /// @notice Burn gUNI and receive UNI. Always instant, no fee.
    function unwrap(uint256 amount, address to) external {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        _burn(msg.sender, amount);
        surrogateOf[delegateOf[msg.sender]].transfer(to, amount);
        emit Unwrapped(msg.sender, to, amount);
    }

    // ───────────────────────────── delegation ─────────────────────────────

    /// @notice Re-point your entire position — wallet balance AND collateral on
    ///         every registered Morpho market — to a new delegate. One call,
    ///         works mid-loan, never touches Morpho.
    function setDelegate(address newDelegatee) external {
        if (newDelegatee == address(0)) revert ZeroAddress();
        address old = delegateOf[msg.sender];
        if (old == newDelegatee) revert SameDelegate();

        delegateOf[msg.sender] = newDelegatee;
        emit DelegateSet(msg.sender, newDelegatee);

        if (old == address(0)) return; // never held anything

        uint256 total = balanceOf(msg.sender) + _collateralAcrossMarkets(msg.sender);
        if (total > 0) {
            surrogateOf[old].transfer(address(_surrogate(newDelegatee)), total);
        }
    }

    /// @notice Total UNI voting for `delegatee` through this wrapper.
    function votesVia(address delegatee) external view returns (uint256) {
        Surrogate s = surrogateOf[delegatee];
        return address(s) == address(0) ? 0 : UNI.balanceOf(address(s));
    }

    // ─────────────────────────── market registry ──────────────────────────

    /// @notice Permissionlessly register a Morpho market that uses gUNI as
    ///         collateral. Required before any supply into it will succeed.
    function registerMarket(MarketParams calldata mp) external {
        if (mp.collateralToken != address(this)) revert MarketNotForThisToken();
        // The only way a wrapper could mint votes is if the governance token
        // (or its wrapper) were borrowable against itself. Refuse such markets.
        if (mp.loanToken == address(UNI) || mp.loanToken == address(this)) revert MarketLoansGovernanceToken();
        Id id = mp.id();
        if (isRegistered[id]) revert MarketAlreadyRegistered();
        if (markets.length >= MAX_MARKETS) revert TooManyMarkets();
        (,,,, uint128 lastUpdate,) = MORPHO.market(id);
        if (lastUpdate == 0) revert MarketNotCreated();
        isRegistered[id] = true;
        markets.push(id);
        emit MarketRegistered(id, mp.loanToken);
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    // ───────────────────────────── liquidation ────────────────────────────

    /// @notice Liquidate `borrower` on a registered market. The liquidator must
    ///         have approved this contract for the loan token. Seized collateral
    ///         is delivered as plain UNI in the same transaction.
    function liquidate(
        MarketParams calldata mp,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) external returns (uint256 seized, uint256 repaid) {
        Id id = mp.id();
        if (!isRegistered[id]) revert MarketNotRegistered();
        if (_ctxActive) revert ContextActive();

        _ctxActive = true;
        _ctxId = Id.unwrap(id);
        _ctxBorrower = borrower;
        _ctxLiquidator = msg.sender;

        (seized, repaid) = MORPHO.liquidate(mp, borrower, seizedAssets, repaidShares, abi.encode(mp.loanToken));

        // The seized gUNI now sits on this contract, backed by the borrower's
        // delegate surrogate (recorded by the hook). Convert to UNI for the liquidator.
        address transit = _ctxTransitDelegate;
        _burn(address(this), seized);
        surrogateOf[transit].transfer(msg.sender, seized);

        _ctxActive = false;
        _ctxId = bytes32(0);
        _ctxBorrower = address(0);
        _ctxLiquidator = address(0);
        _ctxTransitDelegate = address(0);

        emit Liquidated(id, borrower, msg.sender, seized, repaid);
    }

    /// @dev Morpho calls this after transferring the collateral and before pulling
    ///      the loan token. We pull the loan token from the liquidator here.
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(MORPHO)) revert NotMorpho();
        if (!_ctxActive) revert NoContext();
        address loanToken = abi.decode(data, (address));
        IERC20(loanToken).safeTransferFrom(_ctxLiquidator, address(this), repaidAssets);
        IERC20(loanToken).forceApprove(address(MORPHO), repaidAssets);
    }

    // ───────────────────────────── the hook ───────────────────────────────

    /// @dev Every balance change passes through here. Mint/burn are handled by
    ///      their callers; the three routed cases are: into Morpho, out of Morpho,
    ///      and ordinary holder-to-holder.
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }
        if (to == address(MORPHO)) {
            _inbound(from, amount);
        } else if (from == address(MORPHO)) {
            _outbound(to, amount);
        } else {
            _route(from, to, amount);
        }
        super._update(from, to, amount);
    }

    /// @dev gUNI entering Morpho. Morpho has already incremented
    ///      `position(id, onBehalf).collateral`. We only accept the case where
    ///      onBehalf == from (verified against Morpho's state), so the UNI stays
    ///      in `from`'s delegate surrogate and only the mirror changes.
    function _inbound(address from, uint256 amount) private {
        if (from == address(this)) revert DirectTransferToWrapper();
        uint256 n = markets.length;
        for (uint256 i; i < n; ++i) {
            Id id = markets[i];
            uint256 mirrored = collateralOf[id][from];
            (,, uint128 coll) = MORPHO.position(id, from);
            if (uint256(coll) == mirrored + amount) {
                collateralOf[id][from] = mirrored + amount;
                return;
            }
        }
        revert NotAttributable();
    }

    /// @dev gUNI leaving Morpho. Morpho has already decremented the borrower's
    ///      collateral. Either we are inside `liquidate()` and know the borrower,
    ///      or the receiver must be the borrower (direct withdraw-to-self).
    function _outbound(address to, uint256 amount) private {
        if (_ctxActive) {
            if (to != address(this)) revert NotAttributable();
            Id id = Id.wrap(_ctxId);
            address borrower = _ctxBorrower;
            uint256 mirrored = collateralOf[id][borrower];
            (,, uint128 coll) = MORPHO.position(id, borrower);
            if (uint256(coll) + amount != mirrored) revert NotAttributable();
            collateralOf[id][borrower] = mirrored - amount;
            _ctxTransitDelegate = delegateOf[borrower];
            return;
        }
        if (to == address(this)) revert DirectTransferToWrapper();
        uint256 n = markets.length;
        for (uint256 i; i < n; ++i) {
            Id id = markets[i];
            uint256 mirrored = collateralOf[id][to];
            if (mirrored < amount) continue;
            (,, uint128 coll) = MORPHO.position(id, to);
            if (uint256(coll) + amount == mirrored) {
                collateralOf[id][to] = mirrored - amount;
                return;
            }
        }
        revert NotAttributable();
    }

    /// @dev Ordinary transfer. A receiver with no delegate inherits the sender's;
    ///      a receiver with a different delegate gets the UNI moved to theirs.
    function _route(address from, address to, uint256 amount) private {
        if (to == address(this)) revert DirectTransferToWrapper();
        address dFrom = delegateOf[from];
        address dTo = delegateOf[to];
        if (dTo == address(0)) {
            delegateOf[to] = dFrom;
            emit DelegateSet(to, dFrom);
        } else if (dTo != dFrom) {
            surrogateOf[dFrom].transfer(address(_surrogate(dTo)), amount);
        }
    }

    // ───────────────────────────── internals ──────────────────────────────

    function _surrogate(address delegatee) private returns (Surrogate s) {
        s = surrogateOf[delegatee];
        if (address(s) == address(0)) {
            s = new Surrogate{salt: bytes32(uint256(uint160(delegatee)))}(UNI, delegatee);
            surrogateOf[delegatee] = s;
            emit SurrogateDeployed(delegatee, address(s));
        }
    }

    function _collateralAcrossMarkets(address holder) private view returns (uint256 total) {
        uint256 n = markets.length;
        for (uint256 i; i < n; ++i) {
            total += collateralOf[markets[i]][holder];
        }
    }
}
