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

contract DeployScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        BitSyncTimelock timelock = new BitSyncTimelock(1 days, proposers, executors, deployer);

        BSY bsy = new BSY(address(timelock));
        StakingManager staking =
            new StakingManager(address(bsy), address(timelock), 7 days, 10_000 * 10 ** 8);
        SlashingManager slashing =
            new SlashingManager(address(staking), address(timelock), address(timelock), 500);
        FeeManager fees =
            new FeeManager(address(bsy), address(staking), address(timelock), 1 * 10 ** 8 / 100); // 0.01 BSY
        OracleAggregator oracle = new OracleAggregator(address(staking), address(timelock));
        FeedRegistry registry = new FeedRegistry(address(oracle), address(timelock));

        console2.log("Timelock", address(timelock));
        console2.log("BSY", address(bsy));
        console2.log("Staking", address(staking));
        console2.log("Slashing", address(slashing));
        console2.log("Fees", address(fees));
        console2.log("Oracle", address(oracle));
        console2.log("Registry", address(registry));
        console2.log("MAX_SUPPLY", bsy.MAX_SUPPLY());
        console2.log("decimals", bsy.decimals());

        vm.stopBroadcast();
    }
}
