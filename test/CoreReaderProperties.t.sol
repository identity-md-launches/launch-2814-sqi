// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoreReader} from "src/CoreReader.sol";
import {PolicyBook} from "src/PolicyBook.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// forge-config: default.fuzz.runs = 256
contract CoreReaderPropertiesTest is CoverFixture {
    function testFuzz_countIsAdditiveAcrossSupportedWindows(uint256 mask, uint16 gapSeed) public {
        uint64 start = uint64(START + bound(gapSeed, 0, 500));
        // Nonzero cumulative history outside the window must not count as work inside it.
        core.record(start - 1, 100);
        uint16 zeros;
        for (uint64 i; i < 144; ++i) {
            if ((mask >> i) & 1 == 1) core.record(start + i, i + 1);
            else ++zeros;
        }
        core.record(start + 144, 100);
        _certify(start + 144);
        assertEq(reader.countZeroRounds(start, 144), zeros);
        uint16 in24s;
        uint16 in6s;
        for (uint64 i; i < 144; i += 24) {
            in24s += reader.countZeroRounds(start + i, 24);
        }
        for (uint64 i; i < 144; i += 6) {
            in6s += reader.countZeroRounds(start + i, 6);
        }
        assertEq(in24s, zeros);
        assertEq(in6s, zeros);
    }

    function test_allAdditionalPageValidationFailuresPreserveReservations() public {
        (uint256 id,) = _open(alice, 6, 5000, 100 ether);
        core.record(START, 1);
        core.record(START + 1, 1);
        _certify(START + 5);
        bytes memory request = abi.encodeCall(core.roundPage, (START - 1, START + 5, 16));
        uint256 holderBalance = token.balanceOf(alice);
        uint256 assets = pool.totalAssets();
        // Each corruption starts from a fresh valid response, so one guard cannot mask another.
        for (uint256 corruption; corruption < 7; ++corruption) {
            ISqueekCore.RoundPage memory page = core.roundPage(START - 1, START + 5, 16);
            if (corruption == 0) page.start.workPerThousandBlocks = 0;
            else if (corruption == 1) page.rounds[0].workPerThousandBlocks = 0;
            else if (corruption == 2) page.rounds[1].cumulativeBlockUnits = 0;
            else if (corruption == 3) page.end.cumulativeBlockUnits += 1;
            else if (corruption == 4) page.end.workPerThousandBlocks += 1;
            else if (corruption == 5) page.rounds[0].roundId = START - 1;
            else page.rounds = new ISqueekCore.RoundCheckpoint[](17);
            vm.mockCall(address(core), request, abi.encode(page));
            vm.expectRevert(CoreReader.MalformedPage.selector);
            book.settle(id);
            assertEq(uint8(book.getPolicy(id).status), uint8(PolicyBook.Status.Open));
            assertEq(book.getPolicy(id).zeroRounds, 0);
            assertEq(pool.reserved(), 100 ether);
            assertEq(pool.totalAssets(), assets);
            assertEq(token.balanceOf(alice), holderBalance);
            vm.clearMockedCalls();
        }
        assertEq(book.settle(id), 100 ether);
    }

    function test_eachInvalidConfigurationBlocksPurchasesBeforeCollectingPremium() public {
        bytes memory request = abi.encodeCall(core.configuration, ());
        vm.prank(alice);
        token.approve(address(book), 100 ether);
        uint256 holderBalance = token.balanceOf(alice);
        for (uint256 corruption; corruption < 4; ++corruption) {
            ISqueekCore.CoreConfiguration memory config = core.configuration();
            if (corruption == 0) config.genesisTimestamp = 0;
            else if (corruption == 1) config.roundDuration = 601;
            else if (corruption == 2) config.maxRoundsPerBatch = 0;
            else config.maxRoundsPerBatch = 17;
            vm.mockCall(address(core), request, abi.encode(config));
            vm.expectRevert(CoreReader.InvalidConfiguration.selector);
            vm.prank(alice);
            book.openPolicy(START, 6, 5000, 100 ether, 100 ether, block.timestamp);
            assertEq(book.nextPolicyId(), 1);
            assertEq(pool.reserved(), 0);
            assertEq(pool.totalAssets(), 1000 ether);
            assertEq(token.balanceOf(alice), holderBalance);
            assertEq(token.allowance(alice, address(book)), 100 ether);
            vm.clearMockedCalls();
        }
    }

    function testFuzz_snapshotTracksExactClockBoundary(uint32 elapsedRounds, uint16 secondsSeed) public {
        uint256 withinRound = bound(secondsSeed, 0, 599);
        core.setFrontier(elapsedRounds);
        vm.warp(uint256(GENESIS) + uint256(elapsedRounds) * 600 + withinRound);
        (uint64 frontier, uint64 current,) = reader.snapshot();
        assertEq(frontier, elapsedRounds);
        assertEq(current, uint256(elapsedRounds) + 1);
        vm.warp(uint256(GENESIS) + (uint256(elapsedRounds) + 1) * 600);
        (, current,) = reader.snapshot();
        assertEq(current, uint256(elapsedRounds) + 2);
        core.setFrontier(current);
        vm.expectRevert(CoreReader.InconsistentCore.selector);
        reader.snapshot();
    }
}
