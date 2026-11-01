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
}

/// @notice LP capital, earned premiums and fully collateralized cover reservations.
/// @dev Shares are internal and nontransferable. Unsolicited transfers do not change the share price.
contract CoverPool is Managed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant VIRTUAL_SHARES = 1_000_000;
    IERC20 public immutable token;
    address public policyBook;
    uint256 public totalShares;
    uint256 public reserved;
    uint256 private _assets;
    mapping(address lp => uint256 shares) public sharesOf;

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

    event PolicyBookSet(address indexed policyBook);
    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 assets, uint256 shares);
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

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, _assets + 1);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, _assets + 1, totalShares + VIRTUAL_SHARES);
    }

    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (policyBook == address(0)) revert BookNotConfigured();
        if (assets == 0 || minShares == 0) revert InvalidAmount();
        uint256 beforeBalance = _custodyBalance();
        shares = previewDeposit(assets);
        if (shares == 0 || shares < minShares) revert Slippage();
        _assets += assets;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        token.safeTransferFrom(msg.sender, address(this), assets);
        if (token.balanceOf(address(this)) != beforeBalance + assets) revert TokenAmountMismatch();
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Redeem caller-owned shares, bounded by free assets. Reservations cannot be withdrawn.
    function redeem(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (shares == 0 || minAssets == 0) revert InvalidAmount();
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();
        uint256 beforeBalance = _custodyBalance();
        assets = previewRedeem(shares);
        if (assets == 0 || assets < minAssets) revert Slippage();
        if (assets > freeAssets()) revert InsufficientFreeAssets();
        sharesOf[msg.sender] -= shares;
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

    function _custodyBalance() private view returns (uint256 balance) {
        balance = token.balanceOf(address(this));
        if (balance < _assets) revert CustodyShortfall();
    }
}
