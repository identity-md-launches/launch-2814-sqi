// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoverFixture} from "./helpers/CoverFixture.sol";
import {MockCore} from "./helpers/MockCore.sol";
import {MockSQK} from "../src/MockSQK.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoverHandler is Test {
    MockSQK public immutable token;
    CoverPool public immutable pool;
    PolicyBook public immutable book;
    CoreReader public immutable reader;
    MockCore public immutable core;
    address public immutable owner;
    address[3] public actors;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public premiums;
    uint256 public payouts;
    uint256 public donations;
    mapping(uint64 round => bool active) public activeRounds;

    constructor(
        MockSQK token_,
        CoverPool pool_,
        PolicyBook book_,
        address owner_,
        address[3] memory actors_
    ) {
        token = token_;
        pool = pool_;
        book = book_;
        reader = book_.reader();
        core = MockCore(address(reader.core()));
        owner = owner_;
        actors = actors_;
    }

    function deposit(uint8 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        if (book.settlementPending()) return;
        uint256 shares = pool.previewDeposit(amount);
        if (shares == 0) return;
        vm.startPrank(actor);
        token.approve(address(pool), amount);
        pool.deposit(amount, shares);
        vm.stopPrank();
        deposits += amount;
    }

    function redeem(uint8 actorSeed, uint96 shareSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 maximum = Math.mulDiv(
            pool.freeAssets(), pool.totalShares() + pool.VIRTUAL_SHARES(), pool.totalAssets() + 1
        );
        maximum = Math.min(maximum, pool.sharesOf(actor));
        if (maximum == 0 || book.settlementPending()) return;
        uint256 shares = bound(shareSeed, 1, maximum);
        uint256 assets = pool.previewRedeem(shares);
        if (assets == 0) return;
        vm.prank(actor);
        withdrawals += pool.redeem(shares, assets);
    }

    function open(uint8 actorSeed, uint96 coverSeed, uint8 durationSeed, uint8 thresholdSeed) external {
        if (book.paused() || core.paused()) return;
        address actor = actors[actorSeed % 3];
        uint256 maximum = Math.min(pool.freeAssets(), token.balanceOf(actor));
        if (maximum == 0) return;
        uint256 cover = bound(coverSeed, 1, maximum);
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        uint16 n = durations[durationSeed % 4];
        uint16 t = thresholds[thresholdSeed % 3];
        (, uint64 current,) = reader.snapshot();
        (uint256 premium,) = book.quote(current + 1, n, t, cover);
        vm.startPrank(actor);
        token.approve(address(book), premium);
        book.openPolicy(current + 1, n, t, cover, premium, block.timestamp);
        vm.stopPrank();
        premiums += premium;
    }

    function advance(uint8 roundsSeed, uint256 mask) external {
        uint64 old = core.frontier();
        uint64 end = old + uint64(bound(roundsSeed, 1, 144));
        for (uint64 r = old + 1; r <= end; ++r) {
            if (((mask >> (r - old - 1)) & 1) == 1) {
                activeRounds[r] = true;
                core.record(r, 1);
            }
        }
        core.setFrontier(end);
        uint256 endTime = uint256(core.genesis()) + uint256(end) * 600;
        if (endTime > block.timestamp) vm.warp(endTime);
    }

    function settle(uint96 idSeed, uint8 actorSeed) external {
        uint256 count = book.nextPolicyId() - 1;
        if (count == 0) return;
        uint256 id = bound(idSeed, 1, count);
        PolicyBook.Policy memory policy = book.getPolicy(id);
        if (policy.status != PolicyBook.Status.Open || policy.endRound > core.frontier()) return;
        assertTrue(book.settlementPending());
        assertLe(book.earliestOpenEnd(), policy.endRound);
        uint256 zeros;
        for (uint64 r = policy.startRound; r <= policy.endRound; ++r) {
            if (!activeRounds[r]) ++zeros;
        }
        uint256 expected = zeros * 10_000 >= uint256(policy.rounds) * policy.thresholdBps ? policy.cover : 0;
        uint256 before = token.balanceOf(policy.holder);
        vm.prank(actors[actorSeed % 3]);
        uint256 paid = book.settle(id);
        assertEq(paid, expected);
        assertEq(token.balanceOf(policy.holder), before + expected);
        payouts += paid;
    }

    function donate(uint8 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(actor);
        token.transfer(address(pool), amount);
        donations += amount;
    }

    function pause(bool appPaused, bool corePaused) external {
        vm.prank(owner);
        book.setPaused(appPaused);
        core.setPaused(corePaused);
    }

    function elapse(uint24 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 12 * 600));
    }
}

contract SolvencyInvariantTest is CoverFixture {
    CoverHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CoverHandler(token, pool, book, owner, [lp, alice, bob]);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CoverHandler.deposit.selector;
        selectors[1] = CoverHandler.redeem.selector;
        selectors[2] = CoverHandler.open.selector;
        selectors[3] = CoverHandler.advance.selector;
        selectors[4] = CoverHandler.settle.selector;
        selectors[5] = CoverHandler.donate.selector;
        selectors[6] = CoverHandler.pause.selector;
        selectors[7] = CoverHandler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allObligationsRemainFullyBacked() public view {
        uint256 obligations;
        for (uint256 id = 1; id < book.nextPolicyId(); ++id) {
            PolicyBook.Policy memory p = book.getPolicy(id);
            (address beneficiary, uint256 reservedCover) = pool.reservations(id);
            if (p.status == PolicyBook.Status.Open) {
                obligations += p.cover;
                assertEq(reservedCover, p.cover);
                assertEq(beneficiary, p.holder);
            } else {
                assertEq(reservedCover, 0);
                assertTrue(p.status == PolicyBook.Status.Paid || p.status == PolicyBook.Status.Expired);
            }
        }
        assertEq(pool.reserved(), obligations);
        _assertSolvent();
    }

    function invariant_assetsAreConservedAndSharesReconcile() public view {
        assertEq(
            pool.totalAssets() + handler.withdrawals() + handler.payouts(),
            1000 ether + handler.deposits() + handler.premiums()
        );
        assertEq(token.balanceOf(address(pool)), pool.totalAssets() + handler.donations());
        assertEq(pool.totalShares(), pool.sharesOf(lp) + pool.sharesOf(alice) + pool.sharesOf(bob));
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.allowance(address(book), address(pool)), 0);
    }

    function test_handlerExercisesSuccessfulPayoutAndRedemption() public {
        handler.deposit(1, 100 ether);
        handler.open(1, 100 ether, 0, 0);
        handler.advance(7, 0);
        handler.settle(1, 2);
        assertEq(handler.payouts(), 100 ether);
        handler.redeem(0, uint96(10 ether * 1e6));
        assertGt(handler.withdrawals(), 0);
        invariant_allObligationsRemainFullyBacked();
        invariant_assetsAreConservedAndSharesReconcile();
    }
}
