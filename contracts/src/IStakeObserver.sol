// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Hook interface notified by StakingManager around every change of an
///         account's bonded (reward-weighted) stake.
interface IStakeObserver {
    function beforeStakeChange(address account) external;
    function afterStakeChange(address account) external;
}
