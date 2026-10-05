// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BSY} from "../src/BSY.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {SlashingManager} from "../src/SlashingManager.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {FeedRegistry} from "../src/FeedRegistry.sol";
import {BitSyncTimelock} from "../src/BitSyncGovernor.sol";
import {BSYPresale} from "../src/presale/BSYPresale.sol";
import {IAggregatorV3} from "../src/presale/IAggregatorV3.sol";
import {BitSyncTypes} from "../src/BitSyncTypes.sol";

/// @notice Deploys and fully wires the BitSync contract suite.
/// @dev Final state (asserted in test/Deploy.t.sol):
///      - Timelock (proposer/executor/canceller = multisig, self-administered) holds
///        DEFAULT_ADMIN + GOVERNANCE (+ FEED_ADMIN) on every contract and the full
///        42,000,000 BSY genesis supply.
///      - Multisig holds GUARDIAN (pause only) on staking, fees and aggregator.
///      - SlashingManager holds SLASHER on StakingManager.
///      - FeeManager is the StakingManager stake observer.
///      - The deployer retains NO roles.
contract DeployScript is Script {
    struct Config {
        address deployer; // account whose calls create/wire the contracts
        address multisig;
        address compliance; // COMPLIANCE_ROLE holder for KYC (not deployer)
        uint256 timelockDelay;
        uint64 unbondingPeriod;
        uint256 minStake;
        uint16 slashBps;
        uint256 feePerRead;
        uint64 btcUsdMinSigners;
        address ethUsdFeed; // Chainlink-style ETH/USD; address(0) skips presale deploy
    }

    struct Deployment {
        BitSyncTimelock timelock;
        BSY bsy;
        StakingManager staking;
        SlashingManager slashing;
        FeeManager fees;
        OracleAggregator oracle;
        FeedRegistry registry;
        BSYPresale presale;
    }

    function defaultConfig(address deployer, address multisig) public pure returns (Config memory) {
        return defaultConfig(deployer, multisig, multisig);
    }

    function defaultConfig(address deployer, address multisig, address compliance)
        public
        pure
        returns (Config memory)
    {
        return Config({
            deployer: deployer,
            multisig: multisig,
            compliance: compliance,
            timelockDelay: 2 days,
            unbondingPeriod: 7 days,
            minStake: 10_000 * 10 ** 8, // 10,000 BSY (8 decimals)
            slashBps: 1_000, // 10%
            feePerRead: 10 ** 6, // 0.01 BSY
            btcUsdMinSigners: 3,
            ethUsdFeed: address(0)
        });
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envOr("MULTISIG", deployer);
        address compliance = vm.envOr("COMPLIANCE", multisig);
        vm.startBroadcast(pk);
        d = deploy(defaultConfig(deployer, multisig, compliance));
        vm.stopBroadcast();

        console2.log("Timelock ", address(d.timelock));
        console2.log("BSY      ", address(d.bsy));
        console2.log("Staking  ", address(d.staking));
        console2.log("Slashing ", address(d.slashing));
        console2.log("Fees     ", address(d.fees));
        console2.log("Oracle   ", address(d.oracle));
        console2.log("Registry ", address(d.registry));
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        require(c.deployer != address(0) && c.multisig != address(0), "Deploy: zero");

        address[] memory roleHolders = new address[](1);
        roleHolders[0] = c.multisig;
        d.timelock = new BitSyncTimelock(c.timelockDelay, roleHolders, roleHolders, address(0));
        address tl = address(d.timelock);

        d.bsy = new BSY(tl);
        d.staking = new StakingManager(address(d.bsy), c.deployer, c.unbondingPeriod, c.minStake);
        d.fees = new FeeManager(address(d.bsy), address(d.staking), c.deployer, c.feePerRead);
        d.oracle = new OracleAggregator(address(d.staking), c.deployer);
        d.slashing =
            new SlashingManager(address(d.staking), address(d.oracle), c.deployer, tl, c.slashBps);
        d.registry = new FeedRegistry(address(d.oracle), c.deployer);

        // Presale: 15% = 6.3M BSY funded from timelock-held genesis supply.
        // Requires ethUsdFeed; skipped when unset (unit tests that don't need it).
        if (c.ethUsdFeed != address(0)) {
            require(c.compliance != address(0), "Deploy: zero compliance");
            d.presale = new BSYPresale(address(d.bsy), tl, c.deployer, c.ethUsdFeed);
            d.presale.grantRole(d.presale.GUARDIAN_ROLE(), c.multisig);
            d.presale.grantRole(d.presale.COMPLIANCE_ROLE(), c.compliance);
            _handOver(address(d.presale), d.presale.GOVERNANCE_ROLE(), tl, c.deployer);
            _handOverAdmin(address(d.presale), tl, c.deployer);
            // Deployer must not retain COMPLIANCE (BSY-C3).
            if (d.presale.hasRole(d.presale.COMPLIANCE_ROLE(), c.deployer)) {
                IAccessControlLike(address(d.presale)).renounceRole(
                    d.presale.COMPLIANCE_ROLE(), c.deployer
                );
            }
        }

        // --- wiring performed while the deployer still holds admin roles
        d.staking.setStakeObserver(address(d.fees));
        d.staking.grantRole(d.staking.SLASHER_ROLE(), address(d.slashing));
        bytes32 btcUsd = bytes32("BTC/USD"); // == BitSyncTypes.feedIdFromLabel("BTC/USD")
        d.oracle.upsertFeed(btcUsd, 8, c.btcUsdMinSigners, 1 hours);
        d.registry.register("BTC", "USD", btcUsd, "Bitcoin / US Dollar");

        // --- guardian (pause-only) to the multisig
        d.staking.grantRole(d.staking.GUARDIAN_ROLE(), c.multisig);
        d.fees.grantRole(d.fees.GUARDIAN_ROLE(), c.multisig);
        d.oracle.grantRole(d.oracle.GUARDIAN_ROLE(), c.multisig);

        // --- governance + admin to the timelock, then the deployer renounces
        _handOver(address(d.staking), d.staking.GOVERNANCE_ROLE(), tl, c.deployer);
        _handOver(address(d.fees), d.fees.GOVERNANCE_ROLE(), tl, c.deployer);
        _handOver(address(d.slashing), d.slashing.GOVERNANCE_ROLE(), tl, c.deployer);
        _handOver(address(d.registry), d.registry.GOVERNANCE_ROLE(), tl, c.deployer);
        _handOver(address(d.oracle), d.oracle.FEED_ADMIN_ROLE(), tl, c.deployer);
        _handOver(address(d.oracle), d.oracle.GOVERNANCE_ROLE(), tl, c.deployer);
        _handOverAdmin(address(d.staking), tl, c.deployer);
        _handOverAdmin(address(d.fees), tl, c.deployer);
        _handOverAdmin(address(d.slashing), tl, c.deployer);
        _handOverAdmin(address(d.registry), tl, c.deployer);
        _handOverAdmin(address(d.oracle), tl, c.deployer);
    }

    function _handOver(address target, bytes32 role, address to, address from) internal {
        IAccessControlLike(target).grantRole(role, to);
        IAccessControlLike(target).renounceRole(role, from);
    }

    function _handOverAdmin(address target, address to, address from) internal {
        _handOver(target, bytes32(0), to, from);
    }
}

interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
}
