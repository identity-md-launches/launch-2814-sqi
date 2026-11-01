// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoverFixture} from "./helpers/CoverFixture.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";

contract CoreReaderTest is CoverFixture {
    function test_snapshotUsesGenesisAndExact600SecondBoundary() public {
        (uint64 frontier, uint64 current, bool paused) = reader.snapshot();
        assertEq(frontier, 100);
        assertEq(current, 101);
        assertFalse(paused);
        vm.warp(GENESIS + 101 * 600 - 1);
        (, current,) = reader.snapshot();
        assertEq(current, 101);
        vm.warp(GENESIS + 101 * 600);
        (, current,) = reader.snapshot();
        assertEq(current, 102);
        core.setFrontier(0);
        vm.warp(GENESIS - 1);
        (, current,) = reader.snapshot();
        assertEq(current, 0);
        vm.warp(GENESIS);
        (, current,) = reader.snapshot();
        assertEq(current, 1);
    }

    function test_allMissingCertifiedRoundsAreZero() public {
        _certify(START + 143);
        assertEq(reader.countZeroRounds(START, 144), 144);
        assertEq(reader.countZeroRounds(START, 6), 6);
    }

    function test_dense144RoundsRequiresAllNinePages() public {
        for (uint64 r = START; r <= START + 143; ++r) {
            core.record(r, 1);
        }
        _certify(START + 143);
        for (uint64 cursor = START - 1; cursor < START + 143; cursor += 16) {
            vm.expectCall(address(core), abi.encodeCall(core.roundPage, (cursor, START + 143, 16)));
        }
        assertEq(reader.countZeroRounds(START, 144), 0);
    }

    function test_followsReturnedCertificationAcrossGapBeforeNextActiveRound() public {
        for (uint64 r = START; r < START + 16; ++r) {
            core.record(r, 2);
        }
        core.record(START + 20, 10);
        _certify(START + 23);
        // The page stops immediately before record 17, NOT at its last returned active round.
        ISqueekCore.RoundPage memory page = core.roundPage(START - 1, START + 23, 16);
        assertEq(page.certifiedThroughRound, START + 19);
        vm.expectCall(address(core), abi.encodeCall(core.roundPage, (START + 19, START + 23, 16)));
        assertEq(reader.countZeroRounds(START, 24), 7);
    }

    function test_excludesActiveRecordsOutsideInclusivePolicyWindow() public {
        core.record(START - 1, 10);
        core.record(START, 1);
        core.record(START + 5, 1);
        core.record(START + 6, 10);
        _certify(START + 6);
        assertEq(reader.countZeroRounds(START, 6), 4);
    }

    function test_rejectsUnreadableAndUnsupportedCore() public {
        CoreReader unavailable = new CoreReader(makeAddr("no-core-code"));
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        unavailable.snapshot();
        core.setUnavailable(true);
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        reader.snapshot();
        core.setUnavailable(false);
        core.setVersion(4);
        vm.expectRevert(CoreReader.UnsupportedCoreVersion.selector);
        reader.snapshot();
    }

    function test_rejectsInvalidConfigurationAndFutureFrontier() public {
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        config.roundDuration = 0;
        vm.mockCall(address(core), abi.encodeCall(core.configuration, ()), abi.encode(config));
        vm.expectRevert(CoreReader.InvalidConfiguration.selector);
        reader.snapshot();
        vm.clearMockedCalls();
        core.setFrontier(101);
        vm.expectRevert(CoreReader.InconsistentCore.selector);
        reader.snapshot();
        vm.warp(GENESIS - 1);
        vm.expectRevert(CoreReader.InconsistentCore.selector);
        reader.snapshot();
        core.setFrontier(0);
        vm.warp(uint256(GENESIS) + uint256(type(uint64).max) * 600);
        vm.expectRevert(CoreReader.InconsistentCore.selector);
        reader.snapshot();
    }

    function test_coreReadFailureNeverBecomesAZeroWorkPage() public {
        _certify(START + 5);
        vm.mockCallRevert(
            address(core), abi.encodeCall(core.roundPage, (START - 1, START + 5, 16)), "unavailable"
        );
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        reader.countZeroRounds(START, 6);
    }

    function test_rejectsNonAdvancingOrOverreachingPage() public {
        _certify(START + 5);
        ISqueekCore.RoundPage memory page = core.roundPage(START - 1, START + 5, 16);
        page.certifiedThroughRound = START - 1;
        _rejectPage(page, 6);
        page.certifiedThroughRound = START + 6;
        _rejectPage(page, 6);
    }

    function test_rejectsUnderfilledTruncationAndInconsistentEndpoint() public {
        _certify(START + 5);
        ISqueekCore.RoundPage memory page = core.roundPage(START - 1, START + 5, 16);
        page.certifiedThroughRound = START + 4;
        _rejectPage(page, 6);
        page.certifiedThroughRound = START + 5;
        page.end.cumulativeWork = 1;
        _rejectPage(page, 6);
    }

    function test_rejectsDuplicateUnorderedOutOfRangeAndZeroWorkRecords() public {
        core.record(START, 1);
        core.record(START + 1, 1);
        _certify(START + 5);
        ISqueekCore.RoundPage memory page = core.roundPage(START - 1, START + 5, 16);
        page.rounds[1].roundId = START;
        _rejectPage(page, 6);
        page.rounds[1].roundId = START + 6;
        _rejectPage(page, 6);
        page.rounds[1].roundId = START + 1;
        page.rounds[1].cumulativeWork = 1;
        _rejectPage(page, 6);
        page.rounds[1].cumulativeWork = 2;
        page.rounds[1].dataHash = 0;
        _rejectPage(page, 6);
    }

    function test_rejectsDiscontinuousPageStart() public {
        for (uint64 r = START; r < START + 24; ++r) {
            core.record(r, 1);
        }
        _certify(START + 23);
        ISqueekCore.RoundPage memory page = core.roundPage(START + 15, START + 23, 16);
        page.start.cumulativeWork = 0;
        vm.mockCall(
            address(core), abi.encodeCall(core.roundPage, (START + 15, START + 23, 16)), abi.encode(page)
        );
        vm.expectRevert(CoreReader.MalformedPage.selector);
        reader.countZeroRounds(START, 24);
    }

    function testFuzz_sparseWorkMagnitudeDoesNotAffectZeroCount(uint256 activeMask, uint8 durationIndex)
        public
    {
        uint16[4] memory durations = [uint16(6), 12, 24, 144];
        uint16 n = durations[durationIndex % 4];
        uint16 expected;
        for (uint64 i; i < n; ++i) {
            if ((activeMask >> i) & 1 == 1) core.record(START + i, uint64(1 + i * 61));
            else ++expected;
        }
        _certify(START + n - 1);
        assertEq(reader.countZeroRounds(START, n), expected);
    }

    function _rejectPage(ISqueekCore.RoundPage memory page, uint16 n) private {
        vm.mockCall(
            address(core), abi.encodeCall(core.roundPage, (START - 1, START + n - 1, 16)), abi.encode(page)
        );
        vm.expectRevert(CoreReader.MalformedPage.selector);
        reader.countZeroRounds(START, n);
    }
}
