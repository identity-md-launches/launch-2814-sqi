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
        /// @dev Earliest round whose certification could fix the outcome; raised by `review`, never above
        /// `endRound` while the policy is open.
        uint64 decideRound;
        uint16 rounds;
        uint16 thresholdBps;
        /// @dev Zero-work rounds in the certified part of the window at settlement.
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
    mapping(uint64 decideRound => uint256[] policyIds) private _policyIdsByDecide;
    OpenEndRounds.Set private _openEnds;
    OpenEndRounds.Set private _openDecides;

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
    error Undecided(uint256 policyId, uint16 zeroRounds, uint16 certifiedRounds);

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
    event PolicyReviewed(
        uint256 indexed policyId, uint16 zeroRounds, uint16 certifiedRounds, uint64 decideRound
    );
    event PolicySettled(uint256 indexed policyId, uint16 zeroRounds, uint16 certifiedRounds, uint256 payout);

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

    /// @notice Smallest decide round among open policies, or zero when none is open. Once the frontier
    /// reaches it, the policies listed by `openPolicyIdsDecidingAt` must be settled or reviewed before
    /// LPs can move.
    function earliestDecideRound() external view returns (uint64) {
        return _openDecides.earliest;
    }

    /// @notice Ids of still-open policies whose window ends at `endRound`.
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

    /// @notice Ids of still-open policies whose current decide round is `decideRound`; the ones to settle
    /// or review first when the gate is closed.
    function openPolicyIdsDecidingAt(uint64 decideRound) external view returns (uint256[] memory ids) {
        uint256[] storage all = _policyIdsByDecide[decideRound];
        ids = new uint256[](all.length);
        uint256 count;
        for (uint256 i; i < all.length; ++i) {
            Policy storage policy = _policies[all[i]];
            if (policy.status == Status.Open && policy.decideRound == decideRound) ids[count++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    /// @notice True while some open policy must be settled or reviewed against certified history before
    /// LPs may deposit or redeem.
    /// @dev An open policy whose payout certified history has already fixed always has a decide round at
    /// or below the frontier, so the pool refuses deposits and redemptions whenever the earliest decide
    /// round is certified: nobody trades at a share price public history has made stale. The extra history
    /// read runs only on that path. A core whose metadata or history cannot be read lets nothing settle or
    /// review, so it does not block.
    function settlementPending() external view returns (bool) {
        uint64 earliest = _openDecides.earliest;
        if (earliest == 0) return false;
        try reader.snapshot() returns (uint64 frontier, uint64, bool) {
            if (earliest > frontier) return false;
        } catch {
            return false;
        }
        uint256 policyId = _firstOpenDecidingAt(earliest);
        if (policyId == 0) return false;
        Policy storage policy = _policies[policyId];
        try reader.certifiedZeroRounds(policy.startRound, policy.rounds) returns (uint16, uint16) {
            return true;
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
        uint64 decideRound = CoverTerms.nextDecideRound(
            startRound - 1, 0, CoverTerms.requiredZeroRounds(rounds, thresholdBps)
        );
        _policies[policyId] = Policy({
            holder: msg.sender,
            startRound: startRound,
            endRound: endRound,
            decideRound: decideRound,
            rounds: rounds,
            thresholdBps: thresholdBps,
            zeroRounds: 0,
            status: Status.Open,
            cover: cover,
            premium: premium
        });
        _policyIdsByEnd[endRound].push(policyId);
        _openEnds.add(endRound);
        _policyIdsByDecide[decideRound].push(policyId);
        _openDecides.add(decideRound);

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), premium);
        if (token.balanceOf(address(this)) != beforeBalance + premium) revert TokenAmountMismatch();
        token.forceApprove(address(pool), premium);
        pool.lockCover(policyId, msg.sender, cover, premium);
        token.forceApprove(address(pool), 0);
        if (token.balanceOf(address(this)) != beforeBalance) revert TokenAmountMismatch();
        emit PolicyOpened(policyId, msg.sender, startRound, endRound, rounds, thresholdBps, cover, premium);
    }

    /// @notice Anyone can settle, including while paused, once certified history fixes the outcome: when the
    /// whole window is certified, or earlier when the certified prefix alone already holds enough zero-work
    /// rounds to pay, or too many active rounds for the threshold to be reachable.
    /// @dev Reverts `Undecided` otherwise. No timeout can convert unknown history into zero work or release
    /// a reservation: the payout decision uses certified rounds only, and the early decision is one that no
    /// later certified round can change.
    function settle(uint256 policyId) external nonReentrant returns (uint256 payout) {
        Policy storage policy = _policies[policyId];
        if (policy.status != Status.Open) revert PolicyNotOpen();
        (uint16 zeros, uint16 certified) = reader.certifiedZeroRounds(policy.startRound, policy.rounds);
        (bool decided, bool covered) =
            CoverTerms.outcome(zeros, certified, policy.rounds, policy.thresholdBps);
        if (!decided) revert Undecided(policyId, zeros, certified);
        payout = _settle(policyId, policy, zeros, certified, covered);
    }

    /// @notice Settles the policy when certified history has fixed its outcome; otherwise moves its decide
    /// round to the earliest round at which the certified prefix could reach the threshold, which reopens
    /// the LP gate until the frontier gets there. Anyone can call this.
    function review(uint256 policyId) external nonReentrant returns (bool settled, uint64 decideRound) {
        Policy storage policy = _policies[policyId];
        if (policy.status != Status.Open) revert PolicyNotOpen();
        (uint16 zeros, uint16 certified) = reader.certifiedZeroRounds(policy.startRound, policy.rounds);
        (bool decided, bool covered) =
            CoverTerms.outcome(zeros, certified, policy.rounds, policy.thresholdBps);
        if (decided) {
            _settle(policyId, policy, zeros, certified, covered);
            return (true, policy.decideRound);
        }
        decideRound = CoverTerms.nextDecideRound(
            policy.startRound + certified - 1,
            zeros,
            CoverTerms.requiredZeroRounds(policy.rounds, policy.thresholdBps)
        );
        // Undecided implies the remainder can still reach the threshold, so the new bound is within the
        // window and strictly after the last certified round.
        if (decideRound != policy.decideRound) {
            _openDecides.remove(policy.decideRound);
            policy.decideRound = decideRound;
            _policyIdsByDecide[decideRound].push(policyId);
            _openDecides.add(decideRound);
        }
        emit PolicyReviewed(policyId, zeros, certified, decideRound);
    }

    function _settle(uint256 policyId, Policy storage policy, uint16 zeros, uint16 certified, bool covered)
        private
        returns (uint256 payout)
    {
        policy.zeroRounds = zeros;
        policy.status = covered ? Status.Paid : Status.Expired;
        _openEnds.remove(policy.endRound);
        _openDecides.remove(policy.decideRound);
        if (covered) payout = policy.cover;
        pool.resolveCover(policyId, covered);
        emit PolicySettled(policyId, zeros, certified, payout);
    }

    /// @dev One open policy currently keyed at `decideRound`; zero if none (the set guarantees one exists).
    function _firstOpenDecidingAt(uint64 decideRound) private view returns (uint256) {
        uint256[] storage all = _policyIdsByDecide[decideRound];
        for (uint256 i; i < all.length; ++i) {
            Policy storage policy = _policies[all[i]];
            if (policy.status == Status.Open && policy.decideRound == decideRound) return all[i];
        }
        return 0;
    }
}
