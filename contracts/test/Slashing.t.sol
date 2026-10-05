// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {SlashingManager} from "../src/SlashingManager.sol";
import {Report, Observation} from "../src/BitSyncTypes.sol";

contract SlashingTest is BaseTest {
    uint256 internal constant PK = 0xC1;
    address internal op;

    function setUp() public override {
        super.setUp();
        op = _operator(PK, 20_000 * UNIT);
    }

    function test_ReportEquivocationSlashed() public {
        Report memory a = _report(100, 7);
        Report memory b = _report(200, 7);
        uint256 amt = slashing.slashReportEquivocation(
            a, _sign(PK, oracle.reportDigest(a)), b, _sign(PK, oracle.reportDigest(b))
        );
        assertEq(amt, 2_000 * UNIT);
        assertEq(staking.stakedOf(op), 18_000 * UNIT);
        assertEq(bsy.balanceOf(treasury), 2_000 * UNIT);
    }

    function test_ObservationEquivocationSlashed() public {
        Observation memory a = _observation(100, 7);
        Observation memory b = _observation(100_000, 7);
        slashing.slashObservationEquivocation(
            a, _sign(PK, oracle.observationDigest(a)), b, _sign(PK, oracle.observationDigest(b))
        );
        assertEq(staking.stakedOf(op), 18_000 * UNIT);
    }

    /// @dev Honest behaviour: one observation + one (different) report for the same round.
    ///      Distinct EIP-712 types mean this can never be framed as equivocation.
    function test_ObservationPlusReportIsNotEquivocation() public {
        Observation memory o = _observation(100, 7);
        Report memory r = _report(101, 7);
        bytes memory so = _sign(PK, oracle.observationDigest(o));
        bytes memory sr = _sign(PK, oracle.reportDigest(r));
        Report memory oAsReport = Report(o.feedId, o.price, o.confidence, o.timestamp, o.round);
        vm.expectRevert(SlashingManager.SignerMismatch.selector);
        slashing.slashReportEquivocation(oAsReport, so, r, sr);
    }

    function test_DifferentRoundsAreNotEquivocation() public {
        Report memory a = _report(100, 7);
        Report memory b = _report(100, 8);
        bytes memory sa = _sign(PK, oracle.reportDigest(a));
        bytes memory sb = _sign(PK, oracle.reportDigest(b));
        vm.expectRevert(SlashingManager.DifferentFeedOrRound.selector);
        slashing.slashReportEquivocation(a, sa, b, sb);
    }

    function test_IdenticalMessagesRejected() public {
        Report memory a = _report(100, 7);
        bytes memory sa = _sign(PK, oracle.reportDigest(a));
        vm.expectRevert(SlashingManager.IdenticalMessages.selector);
        slashing.slashReportEquivocation(a, sa, a, sa);
    }

    function test_DifferentSignersRejected() public {
        Report memory a = _report(100, 7);
        Report memory b = _report(200, 7);
        bytes memory sa = _sign(PK, oracle.reportDigest(a));
        bytes memory sb = _sign(0xC2, oracle.reportDigest(b));
        vm.expectRevert(SlashingManager.SignerMismatch.selector);
        slashing.slashReportEquivocation(a, sa, b, sb);
    }

    function test_CannotDoubleSlashSameEvidence() public {
        Report memory a = _report(100, 7);
        Report memory b = _report(200, 7);
        Report memory c = _report(300, 7);
        bytes memory sa = _sign(PK, oracle.reportDigest(a));
        bytes memory sb = _sign(PK, oracle.reportDigest(b));
        bytes memory sc = _sign(PK, oracle.reportDigest(c));
        slashing.slashReportEquivocation(a, sa, b, sb);
        vm.expectRevert(SlashingManager.AlreadySlashed.selector);
        slashing.slashReportEquivocation(a, sa, c, sc);
    }

    function test_MaturedUnbondingNotSlashable() public {
        Report memory a = _report(100, 7);
        Report memory b = _report(200, 7);
        bytes memory sa = _sign(PK, oracle.reportDigest(a));
        bytes memory sb = _sign(PK, oracle.reportDigest(b));
        vm.prank(op);
        staking.requestUnbond(20_000 * UNIT);
        vm.warp(block.timestamp + UNBONDING);
        vm.expectRevert(SlashingManager.NothingToSlash.selector);
        slashing.slashReportEquivocation(a, sa, b, sb);
    }

    function testFuzz_SlashReachesUnbonding(uint96 unbondAmt, uint32 elapsed) public {
        uint256 u = bound(uint256(unbondAmt), 1, 20_000 * UNIT);
        uint256 dt = bound(uint256(elapsed), 0, UNBONDING - 1);
        vm.prank(op);
        staking.requestUnbond(u);
        vm.warp(block.timestamp + dt);
        Report memory a = _report(1, 3);
        Report memory b = _report(2, 3);
        uint256 amt = slashing.slashReportEquivocation(
            a, _sign(PK, oracle.reportDigest(a)), b, _sign(PK, oracle.reportDigest(b))
        );
        assertEq(amt, (20_000 * UNIT * SLASH_BPS) / 10_000, "full pre-unbond stake is slashable");
        assertEq(staking.slashableOf(op), 20_000 * UNIT - amt);
    }
}
