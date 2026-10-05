// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Report} from "../src/BitSyncTypes.sol";

contract OracleAggregatorTest is BaseTest {
    uint256 internal constant K1 = 0xB1;
    uint256 internal constant K2 = 0xB2;
    uint256 internal constant K3 = 0xB3;
    uint256 internal constant K4 = 0xB4;

    function _fourEqual() internal {
        _operator(K1, 10_000 * UNIT);
        _operator(K2, 10_000 * UNIT);
        _operator(K3, 10_000 * UNIT);
        _operator(K4, 10_000 * UNIT);
    }

    function _submit(Report memory r, uint256[] memory pks) internal {
        oracle.submitReport(r, _sortedSigs(pks, oracle.reportDigest(r)));
    }

    function _expectQuorumFail(Report memory r, uint256[] memory pks, uint256 signed, uint256 total)
        internal
    {
        bytes[] memory sigs = _sortedSigs(pks, oracle.reportDigest(r));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAggregator.InsufficientStakeQuorum.selector, signed, total)
        );
        oracle.submitReport(r, sigs);
    }

    function test_ThreeOfFourEqualStakeAccepted() public {
        _fourEqual();
        Report memory r = _report(64_250 * int256(UNIT), 1);
        _submit(r, _keys(K1, K2, K3));
        (int256 price,,, uint64 round,) = oracle.latestRoundData(FEED);
        assertEq(price, 64_250 * int256(UNIT));
        assertEq(round, 1);
        (int256 viaRegistry,,,,) = registry.latest("BTC", "USD");
        assertEq(viaRegistry, price);
    }

    function test_TwoOfFourEqualStakeRejected() public {
        _fourEqual();
        _expectQuorumFail(_report(1, 1), _keys(K1, K2), 20_000 * UNIT, 40_000 * UNIT);
    }

    /// @dev Quorum is stake-weighted: a 70% whale alone passes, three 10% operators fail.
    function test_QuorumIsByStakeNotSignerCount() public {
        _operator(K1, 70_000 * UNIT);
        _operator(K2, 10_000 * UNIT);
        _operator(K3, 10_000 * UNIT);
        _operator(K4, 10_000 * UNIT);

        _submit(_report(1, 1), _keys(K1));
        _expectQuorumFail(_report(2, 2), _keys(K2, K3, K4), 30_000 * UNIT, 100_000 * UNIT);
    }

    /// @dev Exactly 2/3 is NOT enough; one base unit more is.
    function test_ExactlyTwoThirdsRejectedJustAboveAccepted() public {
        _operator(K1, 20_000 * UNIT);
        _operator(K2, 10_000 * UNIT);
        Report memory r = _report(1, 1);
        _expectQuorumFail(r, _keys(K1), 20_000 * UNIT, 30_000 * UNIT);

        _stake(vm.addr(K1), 1); // 20_000e8 + 1 of 30_000e8 + 1  => strictly > 2/3
        _submit(r, _keys(K1));
        (,,, uint64 round,) = oracle.latestRoundData(FEED);
        assertEq(round, 1);
    }

    function test_UnsortedOrDuplicateSignersRejected() public {
        _fourEqual();
        Report memory r = _report(1, 1);
        bytes32 d = oracle.reportDigest(r);
        bytes[] memory sorted = _sortedSigs(_keys(K1, K2, K3), d);

        bytes[] memory reversed = new bytes[](3);
        (reversed[0], reversed[1], reversed[2]) = (sorted[2], sorted[1], sorted[0]);
        vm.expectRevert(OracleAggregator.SignersNotAscending.selector);
        oracle.submitReport(r, reversed);

        bytes[] memory dup = new bytes[](3);
        (dup[0], dup[1], dup[2]) = (sorted[0], sorted[0], sorted[1]);
        vm.expectRevert(OracleAggregator.SignersNotAscending.selector);
        oracle.submitReport(r, dup);
    }

    function test_NonOperatorSignerRejected() public {
        _fourEqual();
        Report memory r = _report(1, 1);
        uint256 outsider = 0xDEAD;
        bytes[] memory sigs = _sortedSigs(_keys(outsider), oracle.reportDigest(r));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAggregator.NotActiveOperator.selector, vm.addr(outsider))
        );
        oracle.submitReport(r, sigs);
    }

    function test_DeregisteredOperatorDoesNotCount() public {
        _fourEqual();
        vm.prank(vm.addr(K4));
        staking.deregisterOperator();
        assertEq(staking.totalActiveStake(), 30_000 * UNIT);
        Report memory r = _report(1, 1);
        bytes[] memory bad = _sortedSigs(_keys(K4), oracle.reportDigest(r));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAggregator.NotActiveOperator.selector, vm.addr(K4))
        );
        oracle.submitReport(r, bad);
        _submit(r, _keys(K1, K2, K3));
    }

    function test_RoundMustIncrease() public {
        _fourEqual();
        _submit(_report(1, 5), _keys(K1, K2, K3));
        Report memory older = _report(2, 5);
        bytes[] memory sigs = _sortedSigs(_keys(K1, K2, K3), oracle.reportDigest(older));
        vm.expectRevert(OracleAggregator.StaleRound.selector);
        oracle.submitReport(older, sigs);
    }

    function test_StaleAndFutureTimestampsRejected() public {
        _fourEqual();
        Report memory stale = _report(1, 1);
        stale.timestamp = uint64(block.timestamp - 1 hours - 1);
        bytes[] memory s1 = _sortedSigs(_keys(K1, K2, K3), oracle.reportDigest(stale));
        vm.expectRevert(OracleAggregator.StaleReport.selector);
        oracle.submitReport(stale, s1);

        Report memory fut = _report(1, 1);
        fut.timestamp = uint64(block.timestamp + 61);
        bytes[] memory s2 = _sortedSigs(_keys(K1, K2, K3), oracle.reportDigest(fut));
        vm.expectRevert(OracleAggregator.FutureReport.selector);
        oracle.submitReport(fut, s2);
    }

    function test_MinSignersFloorAndInactiveFeed() public {
        _operator(K1, 90_000 * UNIT);
        _operator(K2, 10_000 * UNIT);
        oracle.upsertFeed(FEED, 8, 2, 1 hours);
        Report memory r = _report(1, 1);
        bytes[] memory one = _sortedSigs(_keys(K1), oracle.reportDigest(r));
        vm.expectRevert(OracleAggregator.TooFewSigners.selector);
        oracle.submitReport(r, one);

        oracle.deactivateFeed(FEED);
        vm.expectRevert(OracleAggregator.FeedInactive.selector);
        oracle.submitReport(r, one);
    }

    function test_NoActiveStakeRejected() public {
        Report memory r = _report(1, 1);
        vm.expectRevert(OracleAggregator.NoActiveStake.selector);
        oracle.submitReport(r, new bytes[](1));
    }

    function test_PausedRejectsReports() public {
        _fourEqual();
        Report memory r = _report(1, 1);
        bytes[] memory sigs = _sortedSigs(_keys(K1, K2, K3), oracle.reportDigest(r));
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        oracle.submitReport(r, sigs);

        vm.prank(guardian);
        vm.expectRevert();
        oracle.unpause();

        oracle.unpause();
        oracle.submitReport(r, sigs);
    }

    /// @dev For arbitrary stakes and signer subsets, acceptance <=> signed*3 > total*2.
    function testFuzz_StakeQuorumRule(uint64[4] memory rawStakes, uint8 mask) public {
        uint256[4] memory pks = [K1, K2, K3, K4];
        uint256 total;
        uint256[4] memory st;
        for (uint256 i = 0; i < 4; i++) {
            st[i] = bound(uint256(rawStakes[i]), MIN_STAKE, 5_000_000 * UNIT);
            _operator(pks[i], st[i]);
            total += st[i];
        }
        mask = uint8(bound(uint256(mask), 1, 15));
        uint256 count;
        for (uint256 i = 0; i < 4; i++) {
            if (mask & (1 << i) != 0) count++;
        }
        uint256[] memory chosen = new uint256[](count);
        uint256 signed;
        uint256 j;
        for (uint256 i = 0; i < 4; i++) {
            if (mask & (1 << i) != 0) {
                chosen[j++] = pks[i];
                signed += st[i];
            }
        }
        Report memory r = _report(42, 1);
        bytes[] memory sigs = _sortedSigs(chosen, oracle.reportDigest(r));
        if (signed * 3 > total * 2) {
            oracle.submitReport(r, sigs);
            (,,, uint64 round,) = oracle.latestRoundData(FEED);
            assertEq(round, 1);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    OracleAggregator.InsufficientStakeQuorum.selector, signed, total
                )
            );
            oracle.submitReport(r, sigs);
        }
    }
}
