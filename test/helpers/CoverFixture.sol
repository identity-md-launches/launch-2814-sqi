// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockSQK} from "../../src/MockSQK.sol";
import {PremiumModel} from "../../src/PremiumModel.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoreReader} from "../../src/CoreReader.sol";
import {PolicyBook} from "../../src/PolicyBook.sol";
import {MockCore} from "./MockCore.sol";

abstract contract CoverFixture is Test {
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant START = 102;
    address internal owner;
    address internal lp;
    address internal alice;
    address internal bob;
    MockSQK internal token;
    PremiumModel internal model;
    CoverPool internal pool;
    CoreReader internal reader;
    PolicyBook internal book;
    MockCore internal core;

    function setUp() public virtual {
        vm.chainId(11_155_111);
        vm.warp(GENESIS + 100 * 600);
        owner = makeAddr("owner");
        lp = makeAddr("lp");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        core = new MockCore(GENESIS);
        core.setFrontier(100);
        token = new MockSQK(owner);
        model = new PremiumModel(owner);
        pool = new CoverPool(owner, address(token));
        reader = new CoreReader(address(core));
        book = new PolicyBook(owner, address(token), address(model), address(pool), address(reader));
        vm.startPrank(owner);
        pool.setPolicyBook(address(book));
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16[3] memory thresholds = [uint16(3000), 5000, 7000];
        for (uint256 i; i < durations.length; ++i) {
            for (uint256 j; j < thresholds.length; ++j) {
                // Explicit test prices only; there are no production defaults.
                model.setRate(durations[i], thresholds[j], 500, 1000);
            }
        }
        token.mint(lp, 10_000 ether);
        token.mint(alice, 10_000 ether);
        token.mint(bob, 10_000 ether);
        vm.stopPrank();
        vm.startPrank(lp);
        token.approve(address(pool), 1000 ether);
        pool.deposit(1000 ether, 1);
        vm.stopPrank();
    }

    function _open(address buyer, uint16 rounds, uint16 threshold, uint256 cover)
        internal
        returns (uint256 id, uint256 premium)
    {
        (premium,) = book.quote(START, rounds, threshold, cover);
        vm.startPrank(buyer);
        token.approve(address(book), premium);
        id = book.openPolicy(START, rounds, threshold, cover, premium, block.timestamp);
        vm.stopPrank();
    }

    function _certify(uint64 end) internal {
        core.setFrontier(end);
        vm.warp(uint256(GENESIS) + uint256(end) * 600);
    }

    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(pool)), pool.totalAssets());
        assertGe(pool.totalAssets(), pool.reserved());
        assertEq(pool.freeAssets() + pool.reserved(), pool.totalAssets());
    }
}
