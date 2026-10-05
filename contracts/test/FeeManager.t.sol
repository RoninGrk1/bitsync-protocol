// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {BSY} from "../src/BSY.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract FeeManagerTest is BaseTest {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal consumer = makeAddr("consumer");

    function setUp() public override {
        super.setUp();
        _fund(consumer, 1_000_000 * UNIT);
        vm.prank(consumer);
        bsy.approve(address(fees), type(uint256).max);
    }

    function _pay(uint256 times) internal {
        for (uint256 i = 0; i < times; i++) {
            vm.prank(consumer);
            fees.payFee(FEED);
        }
    }

    function _claim(address who) internal returns (uint256) {
        vm.prank(who);
        return fees.claim();
    }

    function test_ProRataByStake() public {
        _stake(alice, 30_000 * UNIT);
        _stake(bob, 10_000 * UNIT);
        _pay(4); // 4 BSY
        assertEq(_claim(alice), 3 * UNIT);
        assertEq(_claim(bob), 1 * UNIT);
    }

    /// @dev Staking right before claiming earns nothing from fees paid earlier.
    function test_LateStakerCannotGameClaim() public {
        _stake(alice, 10_000 * UNIT);
        _pay(10);
        _stake(bob, 1_000_000 * UNIT); // whale stakes after fees were paid
        assertEq(fees.pendingRewards(bob), 0);
        vm.prank(bob);
        vm.expectRevert(FeeManager.NothingToClaim.selector);
        fees.claim();
        assertEq(_claim(alice), 10 * UNIT);
    }

    function test_RewardsCheckpointedOnUnbond() public {
        _stake(alice, 10_000 * UNIT);
        _stake(bob, 10_000 * UNIT);
        _pay(2); // 1 each
        vm.prank(alice);
        staking.requestUnbond(10_000 * UNIT); // alice stops earning
        _pay(2); // all to bob
        assertEq(_claim(alice), 1 * UNIT);
        assertEq(_claim(bob), 3 * UNIT);
    }

    function test_RewardsCheckpointedOnSlash() public {
        _stake(alice, 10_000 * UNIT);
        _stake(bob, 10_000 * UNIT);
        _pay(2);
        staking.grantRole(staking.SLASHER_ROLE(), address(this));
        staking.slash(alice, 5_000 * UNIT, treasury); // alice 5k, bob 10k
        _pay(3);
        // Floor division can leave ≤1 base-unit of dust per payout.
        assertApproxEqAbs(_claim(alice), 2 * UNIT, 1);
        assertApproxEqAbs(_claim(bob), 3 * UNIT, 1);
        assertLe(fees.totalClaimed(), fees.totalDeposited());
    }

    function test_FeesWithNoStakeAreCarriedForward() public {
        _pay(5);
        assertEq(fees.undistributed(), 5 * UNIT);
        _stake(alice, 10_000 * UNIT);
        _pay(1);
        assertEq(fees.undistributed(), 0);
        assertEq(_claim(alice), 6 * UNIT);
    }

    function test_HooksOnlyCallableByStaking() public {
        vm.expectRevert(FeeManager.OnlyStaking.selector);
        fees.beforeStakeChange(alice);
        vm.expectRevert(FeeManager.OnlyStaking.selector);
        fees.afterStakeChange(alice);
    }

    function test_PauseBlocksPayAndClaim() public {
        _stake(alice, 10_000 * UNIT);
        _pay(1);
        vm.prank(guardian);
        fees.pause();
        vm.prank(consumer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fees.payFee(FEED);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fees.claim();
        fees.unpause();
        assertEq(_claim(alice), 1 * UNIT);
    }

    /// @dev Arbitrary stakes/fee schedule: claims never exceed deposits.
    function testFuzz_ClaimsNeverExceedDeposits(
        uint64 sa,
        uint64 sb,
        uint64 sc,
        uint8 fees1,
        uint8 fees2,
        uint64 feeAmount
    ) public {
        fees.setFee(bound(uint256(feeAmount), 1, 1_000 * UNIT));
        _stake(alice, bound(uint256(sa), 1, 1_000_000 * UNIT));
        _stake(bob, bound(uint256(sb), 1, 1_000_000 * UNIT));
        _pay(bound(uint256(fees1), 0, 20));
        address carol = makeAddr("carol");
        _stake(carol, bound(uint256(sc), 1, 1_000_000 * UNIT));
        _pay(bound(uint256(fees2), 0, 20));

        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            if (fees.pendingRewards(who[i]) > 0) _claim(who[i]);
        }
        assertLe(fees.totalClaimed(), fees.totalDeposited());
        assertEq(bsy.balanceOf(address(fees)), fees.totalDeposited() - fees.totalClaimed());
    }
}

/// @dev Random sequences of stake / unbond / slash / pay / claim / warp.
contract FeeHandler is Test {
    BSY internal bsy;
    StakingManager internal staking;
    FeeManager internal fees;
    address internal payer;
    address[] public actors;

    constructor(BSY bsy_, StakingManager staking_, FeeManager fees_, address payer_) {
        bsy = bsy_;
        staking = staking_;
        fees = fees_;
        payer = payer_;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(address(uint160(0x1000 + i)));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1, bsy.balanceOf(a));
        if (bsy.balanceOf(a) == 0) return;
        vm.startPrank(a);
        bsy.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function unbond(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 s = staking.stakedOf(a);
        if (s == 0) return;
        vm.prank(a);
        staking.requestUnbond(bound(amount, 1, s));
    }

    function slash(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 s = staking.slashableOf(a);
        if (s == 0) return;
        staking.slash(a, bound(amount, 1, s), address(0xFEE));
    }

    function payFee(uint256 times) external {
        times = bound(times, 1, 5);
        for (uint256 i = 0; i < times; i++) {
            vm.prank(payer);
            fees.payFee(bytes32(0));
        }
    }

    function claim(uint256 seed) external {
        address a = _actor(seed);
        if (fees.pendingRewards(a) == 0) return;
        vm.prank(a);
        fees.claim();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
    }

    function withdraw(uint256 seed) external {
        address a = _actor(seed);
        if (staking.withdrawableOf(a) == 0) return;
        vm.prank(a);
        staking.withdraw();
    }
}

contract FeeManagerInvariantTest is BaseTest {
    FeeHandler internal handler;

    function setUp() public override {
        super.setUp();
        address payer = makeAddr("payer");
        handler = new FeeHandler(bsy, staking, fees, payer);
        staking.grantRole(staking.SLASHER_ROLE(), address(handler));
        fees.setFee(3 * UNIT + 7); // awkward amount to exercise rounding
        _fund(payer, 10_000_000 * UNIT);
        vm.prank(payer);
        bsy.approve(address(fees), type(uint256).max);
        for (uint256 i = 0; i < 4; i++) {
            _fund(handler.actors(i), 1_000_000 * UNIT);
        }
        targetContract(address(handler));
    }

    /// @notice Sum of claims never exceeds deposited fees.
    function invariant_ClaimsLeDeposits() public view {
        assertLe(fees.totalClaimed(), fees.totalDeposited());
    }

    /// @notice FeeManager holds exactly deposits - claims.
    function invariant_BalanceMatchesAccounting() public view {
        assertEq(bsy.balanceOf(address(fees)), fees.totalDeposited() - fees.totalClaimed());
    }

    /// @notice Everything owed to stakers is covered by the contract balance.
    function invariant_OwedCoveredByBalance() public view {
        uint256 owed;
        for (uint256 i = 0; i < 4; i++) {
            owed += fees.pendingRewards(handler.actors(i));
        }
        // pendingRewards is a view over floor-division math and may over-estimate by
        // at most 1 base unit per actor relative to realisable claims.
        assertLe(owed + fees.undistributed(), bsy.balanceOf(address(fees)) + 4);
    }

    /// @notice Staking accounting stays consistent.
    function invariant_TotalStakedMatches() public view {
        uint256 sum;
        for (uint256 i = 0; i < 4; i++) {
            sum += staking.stakedOf(handler.actors(i));
        }
        assertEq(staking.totalStaked(), sum);
        assertLe(bsy.totalSupply(), bsy.MAX_SUPPLY());
    }
}
