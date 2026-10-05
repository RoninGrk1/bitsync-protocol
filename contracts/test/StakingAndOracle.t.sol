// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BSY} from "../src/BSY.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {SlashingManager} from "../src/SlashingManager.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {FeedRegistry} from "../src/FeedRegistry.sol";

contract StakingAndOracleTest is Test {
    BSY internal bsy;
    StakingManager internal staking;
    SlashingManager internal slashing;
    FeeManager internal fees;
    OracleAggregator internal oracle;
    FeedRegistry internal registry;

    address internal admin = address(this);
    address internal treasury;

    uint256 internal op1Pk = 0x1;
    uint256 internal op2Pk = 0x2;
    uint256 internal op3Pk = 0x3;
    address internal op1;
    address internal op2;
    address internal op3;

    bytes32 internal feedId;

    uint256 internal constant MIN_STAKE = 10_000 * 10 ** 8;

    function setUp() public {
        op1 = vm.addr(op1Pk);
        op2 = vm.addr(op2Pk);
        op3 = vm.addr(op3Pk);
        treasury = address(0xBEEF);

        bsy = new BSY(treasury);
        staking = new StakingManager(address(bsy), admin, 1 days, MIN_STAKE);
        slashing = new SlashingManager(address(staking), admin, treasury, 1_000); // 10%
        fees = new FeeManager(address(bsy), address(staking), admin, 1 * 10 ** 8); // 1 BSY
        oracle = new OracleAggregator(address(staking), admin);
        registry = new FeedRegistry(address(oracle), admin);

        staking.grantRole(staking.SLASHER_ROLE(), address(slashing));

        feedId = keccak256("BTC/USD");
        oracle.upsertFeed(feedId, 8, 2, 1 hours);
        registry.register("BTC", "USD", feedId, "Bitcoin / USD");

        // Fund operators
        vm.startPrank(treasury);
        bsy.transfer(op1, 50_000 * 10 ** 8);
        bsy.transfer(op2, 50_000 * 10 ** 8);
        bsy.transfer(op3, 50_000 * 10 ** 8);
        bsy.transfer(address(this), 100_000 * 10 ** 8);
        vm.stopPrank();

        _stakeAndRegister(op1, 20_000 * 10 ** 8);
        _stakeAndRegister(op2, 20_000 * 10 ** 8);
        _stakeAndRegister(op3, 20_000 * 10 ** 8);
    }

    function _stakeAndRegister(address op, uint256 amount) internal {
        vm.startPrank(op);
        bsy.approve(address(staking), amount);
        staking.stake(amount);
        staking.registerOperator("");
        vm.stopPrank();
    }

    function test_StakeUnbond() public {
        vm.startPrank(op1);
        staking.requestUnbond(5_000 * 10 ** 8);
        vm.expectRevert(bytes("Staking: not ready"));
        staking.completeUnbond();
        vm.warp(block.timestamp + 1 days);
        uint256 before = bsy.balanceOf(op1);
        staking.completeUnbond();
        assertEq(bsy.balanceOf(op1), before + 5_000 * 10 ** 8);
        vm.stopPrank();
    }

    function test_SubmitReportQuorum() public {
        OracleAggregator.Report memory report = OracleAggregator.Report({
            feedId: feedId,
            price: int256(6_425_000_000_000),
            confidence: 1_000_000_000,
            timestamp: uint64(block.timestamp),
            round: 1
        });
        bytes32 digest = oracle.reportDigest(report);

        address[] memory ops = new address[](2);
        ops[0] = op1;
        ops[1] = op2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(op1Pk, digest);
        sigs[1] = _sign(op2Pk, digest);

        oracle.submitReport(report, ops, sigs);
        (int256 price,, uint64 ts, uint64 round,) = oracle.latestRoundData(feedId);
        assertEq(price, int256(6_425_000_000_000));
        assertEq(round, 1);
        assertEq(ts, uint64(block.timestamp));

        (int256 p2,,,,) = registry.latest("BTC", "USD");
        assertEq(p2, price);
    }

    function test_RejectBadSig() public {
        OracleAggregator.Report memory report = OracleAggregator.Report({
            feedId: feedId,
            price: 1,
            confidence: 1,
            timestamp: uint64(block.timestamp),
            round: 2
        });
        bytes32 digest = oracle.reportDigest(report);
        address[] memory ops = new address[](2);
        ops[0] = op1;
        ops[1] = op2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(op1Pk, digest);
        sigs[1] = _sign(op3Pk, digest); // signed by op3 but claimed as op2
        vm.expectRevert(bytes("Oracle: bad sig"));
        oracle.submitReport(report, ops, sigs);
    }

    function test_SlashEquivocation() public {
        bytes32 dA = keccak256("A");
        bytes32 dB = keccak256("B");
        bytes memory sA = _sign(op1Pk, dA);
        bytes memory sB = _sign(op1Pk, dB);
        (uint256 stakedBefore,,,,) = staking.stakes(op1);
        uint256 treasuryBefore = bsy.balanceOf(treasury);
        uint256 expectedSlash = (stakedBefore * 1_000) / 10_000;
        slashing.slashEquivocation(op1, feedId, 1, dA, sA, dB, sB);
        (uint256 stakedAfter,,,,) = staking.stakes(op1);
        assertEq(stakedAfter, stakedBefore - expectedSlash);
        assertEq(bsy.balanceOf(treasury), treasuryBefore + expectedSlash);
    }

    function test_FeePayAndClaim() public {
        bsy.approve(address(fees), 10 * 10 ** 8);
        fees.payFee(feedId);
        assertEq(fees.totalAccrued(), 1 * 10 ** 8);

        uint256 before = bsy.balanceOf(op1);
        vm.prank(op1);
        fees.claim();
        assertGt(bsy.balanceOf(op1), before);
    }

    function testFuzz_StakeMath(uint256 amount) public {
        amount = bound(amount, MIN_STAKE, 30_000 * 10 ** 8);
        address op = address(0xABC0);
        vm.prank(treasury);
        bsy.transfer(op, amount);
        vm.startPrank(op);
        bsy.approve(address(staking), amount);
        staking.stake(amount);
        (uint256 staked,,,,) = staking.stakes(op);
        assertEq(staked, amount);
        // supply invariant
        assertLe(bsy.totalSupply(), bsy.MAX_SUPPLY());
        vm.stopPrank();
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
