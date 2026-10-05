// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {Report, Observation, BitSyncTypes} from "../src/BitSyncTypes.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";

/// @notice End-to-end: deploy via the script, then exercise governance, pause,
///         staking, a quorum report and an equivocation slash on the deployed system.
contract DeployTest is Test {
    DeployScript internal script;
    DeployScript.Deployment internal d;
    address internal multisig = makeAddr("multisig");
    uint256 internal constant UNIT = 1e8;
    uint256[4] internal pks = [uint256(0xD1), 0xD2, 0xD3, 0xD4];

    function setUp() public {
        vm.warp(1_700_000_000);
        script = new DeployScript();
        DeployScript.Config memory cfg = script.defaultConfig(address(script), multisig);
        d = script.deploy(cfg);
    }

    function _assertRoles(address deployer) internal view {
        address tl = address(d.timelock);
        // timelock holds admin + governance everywhere
        assertTrue(d.staking.hasRole(bytes32(0), tl));
        assertTrue(d.staking.hasRole(d.staking.GOVERNANCE_ROLE(), tl));
        assertTrue(d.fees.hasRole(bytes32(0), tl));
        assertTrue(d.fees.hasRole(d.fees.GOVERNANCE_ROLE(), tl));
        assertTrue(d.oracle.hasRole(bytes32(0), tl));
        assertTrue(d.oracle.hasRole(d.oracle.GOVERNANCE_ROLE(), tl));
        assertTrue(d.oracle.hasRole(d.oracle.FEED_ADMIN_ROLE(), tl));
        assertTrue(d.slashing.hasRole(bytes32(0), tl));
        assertTrue(d.registry.hasRole(bytes32(0), tl));
        // operational wiring
        assertTrue(d.staking.hasRole(d.staking.SLASHER_ROLE(), address(d.slashing)));
        assertEq(address(d.staking.stakeObserver()), address(d.fees));
        assertTrue(d.staking.hasRole(d.staking.GUARDIAN_ROLE(), multisig));
        assertTrue(d.fees.hasRole(d.fees.GUARDIAN_ROLE(), multisig));
        assertTrue(d.oracle.hasRole(d.oracle.GUARDIAN_ROLE(), multisig));
        assertFalse(d.oracle.hasRole(d.oracle.GOVERNANCE_ROLE(), multisig));
        // multisig drives the timelock
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), multisig));
        assertTrue(d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), multisig));
        // deployer keeps nothing
        assertFalse(d.staking.hasRole(bytes32(0), deployer));
        assertFalse(d.staking.hasRole(d.staking.GOVERNANCE_ROLE(), deployer));
        assertFalse(d.fees.hasRole(bytes32(0), deployer));
        assertFalse(d.oracle.hasRole(bytes32(0), deployer));
        assertFalse(d.oracle.hasRole(d.oracle.FEED_ADMIN_ROLE(), deployer));
        assertFalse(d.slashing.hasRole(bytes32(0), deployer));
        assertFalse(d.registry.hasRole(bytes32(0), deployer));
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer));
        // token genesis
        assertEq(d.bsy.totalSupply(), 42_000_000 * UNIT);
        assertEq(d.bsy.balanceOf(tl), 42_000_000 * UNIT);
        assertEq(d.bsy.decimals(), 8);
    }

    function test_DeployWiresAllRoles() public view {
        _assertRoles(address(script));
    }

    /// @dev Exercise `run()` itself (env-driven, broadcast) and check the same invariants.
    function test_RunEntrypoint() public {
        uint256 pk = 0xBEEF;
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
        vm.setEnv("MULTISIG", vm.toString(multisig));
        d = script.run();
        _assertRoles(vm.addr(pk));
    }

    function _timelockExec(address target, bytes memory data, bytes32 salt) internal {
        uint256 delay = d.timelock.getMinDelay();
        vm.prank(multisig);
        d.timelock.schedule(target, 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(multisig);
        d.timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function test_EndToEndGovernanceStakingReportAndSlash() public {
        // 1. Treasury (timelock) distributes BSY to four operators via governance.
        address[4] memory ops;
        for (uint256 i = 0; i < 4; i++) {
            ops[i] = vm.addr(pks[i]);
            _timelockExec(
                address(d.bsy),
                abi.encodeCall(d.bsy.transfer, (ops[i], 20_000 * UNIT)),
                bytes32(i)
            );
        }
        // 2. Operators stake + register.
        for (uint256 i = 0; i < 4; i++) {
            vm.startPrank(ops[i]);
            d.bsy.approve(address(d.staking), 20_000 * UNIT);
            d.staking.stake(20_000 * UNIT);
            d.staking.registerOperator();
            vm.stopPrank();
        }
        // 3. Quorum report (3 of 4 equal stake, BTC/USD requires >= 3 signers).
        bytes32 feed = bytes32("BTC/USD");
        Report memory r = Report(feed, 64_250 * int256(UNIT), 10 * UNIT, uint64(block.timestamp), 1);
        bytes32 digest = d.oracle.reportDigest(r);
        bytes[] memory sigs = _sorted3(digest);
        d.oracle.submitReport(r, sigs);
        (int256 price,,,,) = d.registry.latest("BTC", "USD");
        assertEq(price, 64_250 * int256(UNIT));

        // 4. Guardian pause; only the timelock can unpause.
        vm.prank(multisig);
        d.oracle.pause();
        assertTrue(d.oracle.paused());
        vm.prank(multisig);
        vm.expectRevert();
        d.oracle.unpause();
        _timelockExec(address(d.oracle), abi.encodeCall(d.oracle.unpause, ()), bytes32("unpause"));
        assertFalse(d.oracle.paused());

        // 5. Equivocation slash works (SlashingManager holds SLASHER_ROLE).
        Observation memory a = Observation(feed, 1, 0, uint64(block.timestamp), 2);
        Observation memory b = Observation(feed, 2, 0, uint64(block.timestamp), 2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pks[0], d.oracle.observationDigest(a));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pks[0], d.oracle.observationDigest(b));
        d.slashing.slashObservationEquivocation(
            a, abi.encodePacked(r1, s1, v1), b, abi.encodePacked(r2, s2, v2)
        );
        assertEq(d.staking.stakedOf(ops[0]), 18_000 * UNIT);
        assertEq(d.bsy.balanceOf(address(d.timelock)), 42_000_000 * UNIT - 80_000 * UNIT + 2_000 * UNIT);
    }


    /// BSY-C3: deployer retains no COMPLIANCE_ROLE; designated compliance holds it.
    function test_Audit_PresaleComplianceHandedOff() public {
        address compliance = makeAddr("complianceSigner");
        DeployScript.Config memory cfg = script.defaultConfig(address(script), multisig, compliance);
        cfg.ethUsdFeed = address(new MockAggregatorV3(8, 2000e8));
        d = script.deploy(cfg);
        assertTrue(d.presale.hasRole(d.presale.COMPLIANCE_ROLE(), compliance));
        assertFalse(d.presale.hasRole(d.presale.COMPLIANCE_ROLE(), address(script)));
        assertFalse(d.presale.hasRole(bytes32(0), address(script)));
        assertFalse(d.presale.hasRole(d.presale.GOVERNANCE_ROLE(), address(script)));
        assertTrue(d.presale.hasRole(bytes32(0), address(d.timelock)));
    }

    /// BSY-H1: registered feed id matches canonical feedIdFromLabel (not keccak).
    function test_Audit_FeedIdMatchesLabelEncoding() public view {
        bytes32 expected = BitSyncTypes.feedIdFromLabel("BTC/USD");
        assertEq(expected, bytes32("BTC/USD"));
        assertTrue(expected != keccak256("BTC/USD"));
        (bool active,,,) = d.oracle.feeds(expected);
        assertTrue(active);
        (bool bad,,,) = d.oracle.feeds(keccak256("BTC/USD"));
        assertFalse(bad);
    }

    function _sorted3(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[3] memory k = [pks[0], pks[1], pks[2]];
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && vm.addr(k[j - 1]) > vm.addr(k[j]); j--) {
                (k[j - 1], k[j]) = (k[j], k[j - 1]);
            }
        }
        sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(k[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }
}
