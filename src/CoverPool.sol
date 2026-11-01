// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Managed} from "./Managed.sol";

interface IPolicyBookWiring {
    function token() external view returns (address);
    function pool() external view returns (address);
    function settlementPending() external view returns (bool);
}

/// @notice LP capital, earned premiums and fully collateralized cover reservations.
/// @dev Shares are internal and nontransferable. Unsolicited transfers do not change the share price.
/// The share supply is bounded so that conversions can never overflow, and shares that have become
/// worthless after a complete loss are retired when the bounded supply can no longer represent a deposit.
contract CoverPool is Managed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant VIRTUAL_SHARES = 1_000_000;
    /// @dev `totalShares + VIRTUAL_SHARES` always fits in uint256, so previews cannot panic.
    uint256 public constant MAX_TOTAL_SHARES = type(uint256).max - VIRTUAL_SHARES;
    IERC20 public immutable token;
    address public policyBook;
    uint256 public totalShares;
    uint256 public reserved;
    /// @notice Current share epoch. Shares of earlier epochs were retired at zero value.
    uint256 public shareEpoch;
    uint256 private _assets;
    mapping(uint256 epoch => mapping(address lp => uint256 shares)) private _shares;

    struct Reservation {
        address beneficiary;
        uint256 cover;
    }

    mapping(uint256 policyId => Reservation) public reservations;
    mapping(uint256 policyId => bool) public usedPolicyIds;

    error InvalidAddress();
    error AlreadyConfigured();
    error BookNotConfigured();
    error InvalidBook();
    error OnlyPolicyBook();
    error InvalidAmount();
    error Slippage();
    error InsufficientShares();
    error InsufficientFreeAssets();
    error InvalidReservation();
    error TokenAmountMismatch();
    error CustodyShortfall();
    error ShareSupplyExhausted();
    error SettlementPending();

    event PolicyBookSet(address indexed policyBook);
    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 assets, uint256 shares);
    event SharesRetired(uint256 indexed retiredEpoch, uint256 retiredShares);
    event CoverReserved(
        uint256 indexed policyId, address indexed beneficiary, uint256 cover, uint256 premium
    );
    event CoverResolved(
        uint256 indexed policyId, address indexed beneficiary, uint256 released, uint256 payout
    );

    constructor(address owner_, address token_) Managed(owner_) {
        if (token_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
    }

    modifier onlyPolicyBook() {
        if (msg.sender != policyBook) revert OnlyPolicyBook();
        _;
    }

    /// @notice One-time owner binding, required because the pool is deployed before PolicyBook.
    /// @dev Deposits and cover are unavailable until this link is configured and checked.
    function setPolicyBook(address book) external onlyOwner {
        if (policyBook != address(0)) revert AlreadyConfigured();
        if (book == address(0) || book.code.length == 0) revert InvalidBook();
        if (
            IPolicyBookWiring(book).token() != address(token)
                || IPolicyBookWiring(book).pool() != address(this)
        ) {
            revert InvalidBook();
        }
        policyBook = book;
        emit PolicyBookSet(book);
    }

    function totalAssets() public view returns (uint256) {
        return _assets;
    }

    function freeAssets() public view returns (uint256) {
        return _assets - reserved;
    }

    /// @notice Shares of `lp` in the current epoch. Retired epochs hold no value and read as zero.
    function sharesOf(address lp) public view returns (uint256) {
        return _shares[shareEpoch][lp];
    }

    function sharesOfEpoch(uint256 epoch, address lp) external view returns (uint256) {
        return _shares[epoch][lp];
    }

    /// @notice Shares a deposit would mint, after any retirement of worthless shares it would trigger.
    /// @dev Reverts with ShareSupplyExhausted when the bounded supply cannot represent the deposit.
    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        bool fits;
        (fits, shares) = _sharesForDeposit(assets, totalShares);
        if (fits) return shares;
        if (_assets != 0) revert ShareSupplyExhausted();
        (fits, shares) = _sharesForDeposit(assets, 0);
        if (!fits) revert ShareSupplyExhausted();
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, _assets + 1, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Deposit collateral for shares. Blocked while a fully certified policy awaits settlement.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (policyBook == address(0)) revert BookNotConfigured();
        if (assets == 0 || minShares == 0) revert InvalidAmount();
        _requireNoPendingSettlement();
        uint256 beforeBalance = _custodyBalance();
        bool fits;
        (fits, shares) = _sharesForDeposit(assets, totalShares);
        if (!fits) {
            // Only shares that are already worthless (zero accounted assets) may be retired.
            if (_assets != 0) revert ShareSupplyExhausted();
            _retireShares();
            (fits, shares) = _sharesForDeposit(assets, 0);
            if (!fits) revert ShareSupplyExhausted();
        }
        if (shares == 0 || shares < minShares) revert Slippage();
        _assets += assets;
        totalShares += shares;
        _shares[shareEpoch][msg.sender] += shares;
        token.safeTransferFrom(msg.sender, address(this), assets);
        if (token.balanceOf(address(this)) != beforeBalance + assets) revert TokenAmountMismatch();
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Redeem caller-owned shares, bounded by free assets. Reservations cannot be withdrawn.
    /// @dev Blocked while a fully certified policy awaits settlement, so nobody exits at a stale price.
    function redeem(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (shares == 0 || minAssets == 0) revert InvalidAmount();
        if (shares > sharesOf(msg.sender)) revert InsufficientShares();
        _requireNoPendingSettlement();
        uint256 beforeBalance = _custodyBalance();
        assets = previewRedeem(shares);
        if (assets == 0 || assets < minAssets) revert Slippage();
        if (assets > freeAssets()) revert InsufficientFreeAssets();
        _shares[shareEpoch][msg.sender] -= shares;
        totalShares -= shares;
        _assets -= assets;
        token.safeTransfer(msg.sender, assets);
        if (token.balanceOf(address(this)) != beforeBalance - assets) revert TokenAmountMismatch();
        emit Withdrawn(msg.sender, assets, shares);
    }

    /// @dev Only the permanently bound book can reserve. Premium comes from that caller's balance.
    function lockCover(uint256 policyId, address beneficiary, uint256 cover, uint256 premium)
        external
        nonReentrant
        onlyPolicyBook
    {
        if (beneficiary == address(0)) revert InvalidAddress();
        if (policyId == 0 || usedPolicyIds[policyId]) revert InvalidReservation();
        if (cover == 0 || premium == 0) revert InvalidAmount();
        if (cover > freeAssets()) revert InsufficientFreeAssets();
        uint256 beforeBalance = _custodyBalance();
        usedPolicyIds[policyId] = true;
        reservations[policyId] = Reservation(beneficiary, cover);
        reserved += cover;
        _assets += premium;
        token.safeTransferFrom(msg.sender, address(this), premium);
        if (token.balanceOf(address(this)) != beforeBalance + premium) revert TokenAmountMismatch();
        emit CoverReserved(policyId, beneficiary, cover, premium);
    }

    /// @dev The beneficiary was fixed at opening. A settler cannot choose the payout address.
    function resolveCover(uint256 policyId, bool covered) external nonReentrant onlyPolicyBook {
        Reservation memory reservation = reservations[policyId];
        if (reservation.cover == 0) revert InvalidReservation();
        uint256 beforeBalance = _custodyBalance();
        delete reservations[policyId];
        reserved -= reservation.cover;
        uint256 payout = 0;
        if (covered) {
            payout = reservation.cover;
            _assets -= payout;
            token.safeTransfer(reservation.beneficiary, payout);
            if (token.balanceOf(address(this)) != beforeBalance - payout) revert TokenAmountMismatch();
        }
        emit CoverResolved(policyId, reservation.beneficiary, reservation.cover, payout);
    }

    /// @dev Shares for `assets` against `supply`, or (false, 0) when the result would overflow or
    /// push the supply past MAX_TOTAL_SHARES. Never panics.
    function _sharesForDeposit(uint256 assets, uint256 supply) private view returns (bool, uint256) {
        (bool ok, uint256 shares) = _tryMulDiv(assets, supply + VIRTUAL_SHARES, _assets + 1);
        if (!ok || shares > MAX_TOTAL_SHARES - supply) return (false, 0);
        return (true, shares);
    }

    /// @dev Full-precision x * y / d with an explicit overflow signal instead of a panic. `d` is nonzero.
    function _tryMulDiv(uint256 x, uint256 y, uint256 d) private pure returns (bool ok, uint256 result) {
        uint256 high;
        assembly ("memory-safe") {
            let mm := mulmod(x, y, not(0))
            let low := mul(x, y)
            high := sub(sub(mm, low), lt(mm, low))
        }
        if (high >= d) return (false, 0);
        return (true, Math.mulDiv(x, y, d));
    }

    /// @dev Called only when accounted assets are zero: every outstanding share is worth nothing, so
    /// no holder loses value when the supply is restarted for the recapitalizing deposit.
    function _retireShares() private {
        uint256 retired = totalShares;
        emit SharesRetired(shareEpoch, retired);
        totalShares = 0;
        ++shareEpoch;
    }

    /// @dev Share prices are stale while a fully certified policy is unsettled. Anyone may settle it,
    /// including the caller, and retry. A core the book cannot read cannot settle anything either, so the
    /// gate fails open rather than freezing free liquidity.
    function _requireNoPendingSettlement() private view {
        if (IPolicyBookWiring(policyBook).settlementPending()) revert SettlementPending();
    }

    function _custodyBalance() private view returns (uint256 balance) {
        balance = token.balanceOf(address(this));
        if (balance < _assets) revert CustodyShortfall();
    }
}
