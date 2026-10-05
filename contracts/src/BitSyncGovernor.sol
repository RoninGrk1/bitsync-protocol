// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title BitSyncTimelock
/// @notice Multisig-controlled timelock. Progressive decentralization path:
///         Phase 0: deployer EOA (test only)
///         Phase 1: 3/5 multisig as sole proposer+executor (current production target)
///         Phase 2: add on-chain Governor with BSY voting as additional proposer
///         Phase 3: revoke multisig proposer; community Governor only
///         See docs/GOVERNANCE.md.
contract BitSyncTimelock is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
