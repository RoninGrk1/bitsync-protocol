// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BSY} from "../src/BSY.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {SlashingManager} from "../src/SlashingManager.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {FeedRegistry} from "../src/FeedRegistry.sol";
import {Report, Observation} from "../src/BitSyncTypes.sol";

/// @dev Shared fixture. The test contract is the BSY treasury and governance; a
///      separate `guardian` holds pause rights.
abstract contract BaseTest is Test {
    uint256 internal constant UNIT = 1e8; // 1 BSY in base units
    uint256 internal constant MIN_STAKE = 10_000 * UNIT;
    uint64 internal constant UNBONDING = 7 days;
    uint16 internal constant SLASH_BPS = 1_000; // 10%
    bytes32 internal constant FEED = keccak256("BTC/USD");

    BSY internal bsy;
    StakingManager internal staking;
    FeeManager internal fees;
    OracleAggregator internal oracle;
    SlashingManager internal slashing;
    FeedRegistry internal registry;

    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        bsy = new BSY(address(this));
        staking = new StakingManager(address(bsy), address(this), UNBONDING, MIN_STAKE);
        fees = new FeeManager(address(bsy), address(staking), address(this), 1 * UNIT);
        oracle = new OracleAggregator(address(staking), address(this));
        slashing =
            new SlashingManager(address(staking), address(oracle), address(this), treasury, SLASH_BPS);
        registry = new FeedRegistry(address(oracle), address(this));

        staking.setStakeObserver(address(fees));
        staking.grantRole(staking.SLASHER_ROLE(), address(slashing));
        staking.grantRole(staking.GUARDIAN_ROLE(), guardian);
        fees.grantRole(fees.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        oracle.upsertFeed(FEED, 8, 1, 1 hours);
        registry.register("BTC", "USD", FEED, "Bitcoin / US Dollar");
    }

    function _fund(address to, uint256 amount) internal {
        bsy.transfer(to, amount);
    }

    function _stake(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        bsy.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _operator(uint256 pk, uint256 amount) internal returns (address op) {
        op = vm.addr(pk);
        _stake(op, amount);
        vm.prank(op);
        staking.registerOperator();
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign `digest` with each key and return signatures ordered by ascending signer.
    function _sortedSigs(uint256[] memory pks, bytes32 digest)
        internal
        pure
        returns (bytes[] memory sigs)
    {
        uint256 n = pks.length;
        address[] memory addrs = new address[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            keys[i] = pks[i];
            addrs[i] = vm.addr(pks[i]);
        }
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && addrs[j - 1] > addrs[j]; j--) {
                (addrs[j - 1], addrs[j]) = (addrs[j], addrs[j - 1]);
                (keys[j - 1], keys[j]) = (keys[j], keys[j - 1]);
            }
        }
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            sigs[i] = _sign(keys[i], digest);
        }
    }

    function _report(int256 price, uint64 round) internal view returns (Report memory) {
        return Report({
            feedId: FEED,
            price: price,
            confidence: 10 * UNIT,
            timestamp: uint64(block.timestamp),
            round: round
        });
    }

    function _observation(int256 price, uint64 round) internal view returns (Observation memory) {
        return Observation({
            feedId: FEED,
            price: price,
            confidence: 10 * UNIT,
            timestamp: uint64(block.timestamp),
            round: round
        });
    }

    function _keys(uint256 a) internal pure returns (uint256[] memory k) {
        k = new uint256[](1);
        k[0] = a;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory k) {
        k = new uint256[](2);
        (k[0], k[1]) = (a, b);
    }

    function _keys(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory k) {
        k = new uint256[](3);
        (k[0], k[1], k[2]) = (a, b, c);
    }
}
