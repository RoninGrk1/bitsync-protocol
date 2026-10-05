// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BSY} from "../src/BSY.sol";
import {BSYPresale} from "../src/presale/BSYPresale.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeployLocalPresale is Script {
    function run() external {
        uint256 pk = vm.envOr(
            "PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        BSY bsy = new BSY(deployer);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 2000e8);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        usdc.mint(deployer, 10_000_000e6);
        usdt.mint(deployer, 10_000_000e6);

        BSYPresale sale = new BSYPresale(address(bsy), deployer, deployer, address(feed));
        sale.grantRole(sale.GUARDIAN_ROLE(), deployer);
        sale.grantRole(sale.COMPLIANCE_ROLE(), deployer); // local demo only

        uint64 start = uint64(block.timestamp);
        sale.setConfig(
            BSYPresale.SaleConfig({
                start: start,
                end: start + 30 days,
                tge: start + 37 days,
                priceUsdPerBsy: 20_000_000,
                softCapBsy: 1_000_000 * 1e8,
                minBuyUsd: 10 * 1e8,
                maxBuyUsd: 100_000 * 1e8,
                tgeUnlockBps: 2500,
                vestingDuration: 90 days,
                oracleMaxStale: 1 hours,
                kycRequired: false
            })
        );
        sale.setStable(address(usdc), true);
        sale.setStable(address(usdt), true);
        bsy.approve(address(sale), sale.PRESALE_ALLOCATION());
        sale.fund(deployer);

        vm.stopBroadcast();
        console2.log("BSY", address(bsy));
        console2.log("Presale", address(sale));
        console2.log("EthUsdFeed", address(feed));
        console2.log("USDC", address(usdc));
        console2.log("USDT", address(usdt));
    }
}
