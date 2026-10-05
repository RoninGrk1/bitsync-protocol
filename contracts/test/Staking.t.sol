// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Report, Observation} from "../src/BitSyncTypes.sol";

contract StakingTest is BaseTest {
    uint256 internal constant PK1 = 0xA1;
    uint256 internal constant PK2 = 0xA2;

    function test_StakeRegisterUnbondWithdraw() public {
        address op = _operator(PK1, 20_000 * UNIT);
        assertTrue(staking.isOperator(op));
        assertEq(staking.totalActiveStake(), 20_000 * UNIT);

        vm.prank(op);
        staking.requestUnbond(5_000 * UNIT);
        assertEq(staking.stakedOf(op), 15_000 * UNIT);
        assertEq(staking.totalActiveStake(), 15_000 * UNIT);

        vm.prank(op);
        vm.expectRevert(StakingManager.NothingToWithdraw.selector);
        staking.withdraw();

        vm.warp(block.timestamp + UNBONDING);
        uint256 before = bsy.balanceOf(op);
        vm.prank(op);
        staking.withdraw();
        assertEq(bsy.balanceOf(op), before + 5_000 * UNIT);
    }

    function test_AutoDeregisterBelowMin() public {
        address op = _operator(PK1, 12_000 * UNIT);
        vm.prank(op);
        staking.requestUnbond(3_000 * UNIT);
        assertFalse(staking.isOperator(op));
        assertEq(staking.totalActiveStake(), 0);
        assertEq(staking.totalStaked(), 9_000 * UNIT);
    }

    function test_SlashableIncludesPendingUnbonding() public {
        address op = _operator(PK1, 20_000 * UNIT);
        vm.prank(op);
        staking.requestUnbond(20_000 * UNIT);
        assertEq(staking.stakedOf(op), 0);
        assertEq(staking.slashableOf(op), 20_000 * UNIT);

        vm.warp(block.timestamp + UNBONDING - 1);
        assertEq(staking.slashableOf(op), 20_000 * UNIT);
        vm.warp(block.timestamp + 1);
        assertEq(staking.slashableOf(op), 0, "matured entries are not slashable");
    }

    function test_SlashTakesBondedThenUnbonding() public {
        address op = _operator(PK1, 20_000 * UNIT);
        vm.prank(op);
        staking.requestUnbond(15_000 * UNIT); // 5k bonded, 15k unbonding

        staking.grantRole(staking.SLASHER_ROLE(), address(this));
        staking.slash(op, 8_000 * UNIT, treasury);
        assertEq(staking.stakedOf(op), 0);
        assertEq(staking.slashableOf(op), 12_000 * UNIT);
        assertEq(bsy.balanceOf(treasury), 8_000 * UNIT);

        vm.warp(block.timestamp + UNBONDING);
        vm.prank(op);
        staking.withdraw();
        assertEq(bsy.balanceOf(op), 12_000 * UNIT);
    }

    function test_SlashCannotExceedSlashable() public {
        address op = _operator(PK1, 20_000 * UNIT);
        staking.grantRole(staking.SLASHER_ROLE(), address(this));
        vm.expectRevert(StakingManager.SlashExceedsSlashable.selector);
        staking.slash(op, 20_000 * UNIT + 1, treasury);
    }

    function test_OnlySlasherCanSlash() public {
        address op = _operator(PK1, 20_000 * UNIT);
        vm.prank(op);
        vm.expectRevert();
        staking.slash(op, 1, op);
    }

    /// @dev Equivocate, then immediately unbond everything: the slash still lands.
    function test_UnbondingDoesNotDodgeEquivocationSlash() public {
        address op = _operator(PK1, 20_000 * UNIT);
        Report memory a = _report(100 * int256(UNIT), 1);
        Report memory b = _report(101 * int256(UNIT), 1);
        bytes memory sa = _sign(PK1, oracle.reportDigest(a));
        bytes memory sb = _sign(PK1, oracle.reportDigest(b));

        vm.prank(op);
        staking.requestUnbond(20_000 * UNIT);

        vm.warp(block.timestamp + 3 days); // still inside unbonding period
        uint256 slashedAmt = slashing.slashReportEquivocation(a, sa, b, sb);
        assertEq(slashedAmt, 2_000 * UNIT);
        assertEq(bsy.balanceOf(treasury), 2_000 * UNIT);

        vm.warp(block.timestamp + UNBONDING);
        vm.prank(op);
        staking.withdraw();
        assertEq(bsy.balanceOf(op), 18_000 * UNIT);
    }

    function test_PauseByGuardianUnpauseByGovernance() public {
        address op = vm.addr(PK1);
        _fund(op, 20_000 * UNIT);
        vm.prank(op);
        bsy.approve(address(staking), type(uint256).max);

        vm.startPrank(op);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, op, staking.GUARDIAN_ROLE()
            )
        );
        staking.pause();
        vm.stopPrank();

        vm.prank(guardian);
        staking.pause();
        vm.startPrank(op);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake(1);
        vm.stopPrank();

        vm.startPrank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                guardian,
                staking.GOVERNANCE_ROLE()
            )
        );
        staking.unpause();
        vm.stopPrank();

        staking.unpause(); // governance (this)
        vm.prank(op);
        staking.stake(20_000 * UNIT);
        assertEq(staking.stakedOf(op), 20_000 * UNIT);
    }

    function test_SlashingStillWorksWhilePaused() public {
        address op = _operator(PK1, 20_000 * UNIT);
        vm.prank(guardian);
        staking.pause();
        Observation memory a = _observation(1, 9);
        Observation memory b = _observation(2, 9);
        slashing.slashObservationEquivocation(
            a, _sign(PK1, oracle.observationDigest(a)), b, _sign(PK1, oracle.observationDigest(b))
        );
        assertEq(staking.stakedOf(op), 18_000 * UNIT);
    }

    function test_ObserverCanOnlyBeSetOnce() public {
        vm.expectRevert(StakingManager.ObserverAlreadySet.selector);
        staking.setStakeObserver(address(0xBEEF));
    }

    function testFuzz_ActiveStakeAccounting(uint96 a, uint96 b, uint96 unbondA) public {
        uint256 sa = bound(uint256(a), MIN_STAKE, 1_000_000 * UNIT);
        uint256 sb = bound(uint256(b), MIN_STAKE, 1_000_000 * UNIT);
        address opA = _operator(PK1, sa);
        address opB = _operator(PK2, sb);
        uint256 u = bound(uint256(unbondA), 1, sa);
        vm.prank(opA);
        staking.requestUnbond(u);

        uint256 expected = staking.activeStakeOf(opA) + staking.activeStakeOf(opB);
        assertEq(staking.totalActiveStake(), expected);
        assertEq(staking.totalStaked(), sa + sb - u);
        assertEq(staking.slashableOf(opA), sa);
        assertLe(bsy.totalSupply(), bsy.MAX_SUPPLY());
    }
}
