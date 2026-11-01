// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Managed} from "./Managed.sol";
import {CoverTerms} from "./CoverTerms.sol";
import {OpenEndRounds} from "./OpenEndRounds.sol";
import {PremiumModel} from "./PremiumModel.sol";
import {CoreReader} from "./CoreReader.sol";
import {CoverPool} from "./CoverPool.sol";

/// @notice Fixed-payout, zero-work round COVER using only certified SqueekCore history.
contract PolicyBook is Managed, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OpenEndRounds for OpenEndRounds.Set;

    enum Status {
        None,
        Open,
        Paid,
        Expired
    }

    struct Policy {
        address holder;
        uint64 startRound;
        uint64 endRound;
        uint16 rounds;
        uint16 thresholdBps;
        uint16 zeroRounds;
        Status status;
        uint256 cover;
        uint256 premium;
    }

    /// @notice A window may start at most this many rounds (seven days) after the wall-clock round.
    /// @dev Bounds how long one premium can keep LP capital reserved before the core can certify it.
    uint64 public constant MAX_LEAD_ROUNDS = 1008;

    IERC20 public immutable token;
    PremiumModel public immutable premiumModel;
    CoverPool public immutable pool;
    CoreReader public immutable reader;
    bool public paused;
    uint256 public nextPolicyId = 1;
    mapping(uint256 policyId => Policy) private _policies;
    mapping(uint64 endRound => uint256[] policyIds) private _policyIdsByEnd;
    OpenEndRounds.Set private _openEnds;

    error InvalidAddress();
    error NotConfigured();
    error OpeningPaused();
    error CorePaused();
    error StartNotFuture(uint64 startRound, uint64 frontier, uint64 currentRound);
    error StartTooFar(uint64 startRound, uint64 latestAllowed);
    error DeadlineExpired();
    error PremiumExceeded(uint256 premium, uint256 maximum);
    error TokenAmountMismatch();
    error PolicyNotOpen();

    event PauseSet(bool paused);
    event PolicyOpened(
        uint256 indexed policyId,
        address indexed holder,
        uint64 startRound,
        uint64 endRound,
        uint16 rounds,
        uint16 thresholdBps,
        uint256 cover,
        uint256 premium
    );
    event PolicySettled(uint256 indexed policyId, uint16 zeroRounds, uint256 payout);

    constructor(address owner_, address token_, address premiumModel_, address pool_, address reader_)
        Managed(owner_)
    {
        if (
            token_ == address(0) || premiumModel_ == address(0) || pool_ == address(0)
                || reader_ == address(0)
        ) {
            revert InvalidAddress();
        }
        token = IERC20(token_);
        premiumModel = PremiumModel(premiumModel_);
        pool = CoverPool(pool_);
        reader = CoreReader(reader_);
    }

    /// @notice Stops new cover only. Certified settlement and LP redemptions remain available.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PauseSet(value);
    }

    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        return _policies[policyId];
    }

    function openPolicyCount() external view returns (uint256) {
        return _openEnds.count;
    }

    /// @notice Smallest end round among open policies, or zero when none is open.
    function earliestOpenEnd() external view returns (uint64) {
        return _openEnds.earliest;
    }

    /// @notice Ids of still-open policies whose window ends at `endRound`; the ones to settle first.
    function openPolicyIdsEndingAt(uint64 endRound) external view returns (uint256[] memory ids) {
        uint256[] storage all = _policyIdsByEnd[endRound];
        ids = new uint256[](all.length);
        uint256 count;
        for (uint256 i; i < all.length; ++i) {
            if (_policies[all[i]].status == Status.Open) ids[count++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    /// @notice True while some open policy is fully certified but not yet settled.
    /// @dev The pool refuses deposits and redemptions in that state so nobody trades at a share price that
    /// public history has already made stale. An unreadable core settles nothing, so it does not block.
    function settlementPending() external view returns (bool) {
        uint64 earliest = _openEnds.earliest;
        if (earliest == 0) return false;
        try reader.snapshot() returns (uint64 frontier, uint64, bool) {
            return earliest <= frontier;
        } catch {
            return false;
        }
    }

    function quote(uint64 startRound, uint16 rounds, uint16 thresholdBps, uint256 cover)
        public
        view
        returns (uint256 premium, uint64 endRound)
    {
        if (paused) revert OpeningPaused();
        CoverTerms.validate(rounds, thresholdBps);
        endRound = CoverTerms.endRound(startRound, rounds);
        if (pool.policyBook() != address(this) || address(pool.token()) != address(token)) {
            revert NotConfigured();
        }
        (uint64 frontier, uint64 currentRound, bool corePaused) = reader.snapshot();
        if (corePaused) revert CorePaused();
        if (startRound <= frontier || startRound <= currentRound) {
            revert StartNotFuture(startRound, frontier, currentRound);
        }
        uint256 latestAllowed = uint256(currentRound) + MAX_LEAD_ROUNDS;
        if (startRound > latestAllowed) revert StartTooFar(startRound, uint64(latestAllowed));
        (premium,) = premiumModel.quote(rounds, thresholdBps, cover, pool.totalAssets(), pool.reserved());
    }

    /// @notice The caller pays the quoted premium and is the fixed beneficiary of C, if triggered.
    function openPolicy(
        uint64 startRound,
        uint16 rounds,
        uint16 thresholdBps,
        uint256 cover,
        uint256 maxPremium,
        uint256 deadline
    ) external nonReentrant returns (uint256 policyId) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        (uint256 premium, uint64 endRound) = quote(startRound, rounds, thresholdBps, cover);
        if (premium > maxPremium) revert PremiumExceeded(premium, maxPremium);
        policyId = nextPolicyId++;
        _policies[policyId] = Policy({
            holder: msg.sender,
            startRound: startRound,
            endRound: endRound,
            rounds: rounds,
            thresholdBps: thresholdBps,
            zeroRounds: 0,
            status: Status.Open,
            cover: cover,
            premium: premium
        });
        _policyIdsByEnd[endRound].push(policyId);
        _openEnds.add(endRound);

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), premium);
        if (token.balanceOf(address(this)) != beforeBalance + premium) revert TokenAmountMismatch();
        token.forceApprove(address(pool), premium);
        pool.lockCover(policyId, msg.sender, cover, premium);
        token.forceApprove(address(pool), 0);
        if (token.balanceOf(address(this)) != beforeBalance) revert TokenAmountMismatch();
        emit PolicyOpened(policyId, msg.sender, startRound, endRound, rounds, thresholdBps, cover, premium);
    }

    /// @notice Anyone can settle, including while paused, once the entire window is certified.
    /// @dev No timeout can convert unknown history into zero work or release its reservation.
    function settle(uint256 policyId) external nonReentrant returns (uint256 payout) {
        Policy storage policy = _policies[policyId];
        if (policy.status != Status.Open) revert PolicyNotOpen();
        uint16 zeros = reader.countZeroRounds(policy.startRound, policy.rounds);
        bool covered = CoverTerms.triggered(zeros, policy.rounds, policy.thresholdBps);
        policy.zeroRounds = zeros;
        policy.status = covered ? Status.Paid : Status.Expired;
        _openEnds.remove(policy.endRound);
        if (covered) payout = policy.cover;
        pool.resolveCover(policyId, covered);
        emit PolicySettled(policyId, zeros, payout);
    }
}
