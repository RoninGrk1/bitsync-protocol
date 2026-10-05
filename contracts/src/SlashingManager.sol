// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {StakingManager} from "./StakingManager.sol";
import {OracleAggregator} from "./OracleAggregator.sol";
import {Report, Observation} from "./BitSyncTypes.sol";

/// @title SlashingManager
/// @notice Permissionless slashing for provable equivocation: an operator signing two
///         DIFFERENT reports (or two different observations) for the same feed and
///         round. Evidence is bound to typed EIP-712 structs, so unrelated signatures
///         (e.g. legit reports from different rounds) can never be passed off as
///         equivocation. Slashing reaches unbonding stake (see StakingManager).
contract SlashingManager is AccessControl {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint8 internal constant KIND_REPORT = 1;
    uint8 internal constant KIND_OBSERVATION = 2;

    StakingManager public immutable staking;
    OracleAggregator public immutable aggregator;
    address public treasury;
    uint16 public slashBps;

    /// @notice One slash per (operator, kind, feed, round).
    mapping(bytes32 => bool) public slashed;

    event EquivocationSlashed(
        address indexed operator, uint8 kind, bytes32 indexed feedId, uint64 round, uint256 amount
    );
    event ParamsUpdated(address treasury, uint16 slashBps);

    error ZeroAddress();
    error InvalidBps();
    error DifferentFeedOrRound();
    error IdenticalMessages();
    error SignerMismatch();
    error AlreadySlashed();
    error NothingToSlash();

    constructor(
        address staking_,
        address aggregator_,
        address admin,
        address treasury_,
        uint16 slashBps_
    ) {
        if (
            staking_ == address(0) || aggregator_ == address(0) || admin == address(0)
                || treasury_ == address(0)
        ) revert ZeroAddress();
        if (slashBps_ == 0 || slashBps_ > 10_000) revert InvalidBps();
        staking = StakingManager(staking_);
        aggregator = OracleAggregator(aggregator_);
        treasury = treasury_;
        slashBps = slashBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function setParams(address treasury_, uint16 slashBps_) external onlyRole(GOVERNANCE_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (slashBps_ == 0 || slashBps_ > 10_000) revert InvalidBps();
        treasury = treasury_;
        slashBps = slashBps_;
        emit ParamsUpdated(treasury_, slashBps_);
    }

    function slashReportEquivocation(
        Report calldata a,
        bytes calldata sigA,
        Report calldata b,
        bytes calldata sigB
    ) external returns (uint256) {
        if (a.feedId != b.feedId || a.round != b.round) revert DifferentFeedOrRound();
        bytes32 da = aggregator.reportDigest(a);
        bytes32 db = aggregator.reportDigest(b);
        return _slash(KIND_REPORT, a.feedId, a.round, da, sigA, db, sigB);
    }

    function slashObservationEquivocation(
        Observation calldata a,
        bytes calldata sigA,
        Observation calldata b,
        bytes calldata sigB
    ) external returns (uint256) {
        if (a.feedId != b.feedId || a.round != b.round) revert DifferentFeedOrRound();
        bytes32 da = aggregator.observationDigest(a);
        bytes32 db = aggregator.observationDigest(b);
        return _slash(KIND_OBSERVATION, a.feedId, a.round, da, sigA, db, sigB);
    }

    function _slash(
        uint8 kind,
        bytes32 feedId,
        uint64 round,
        bytes32 da,
        bytes calldata sigA,
        bytes32 db,
        bytes calldata sigB
    ) internal returns (uint256 amount) {
        if (da == db) revert IdenticalMessages();
        address operator = ECDSA.recover(da, sigA);
        if (ECDSA.recover(db, sigB) != operator) revert SignerMismatch();

        bytes32 key = keccak256(abi.encode(operator, kind, feedId, round));
        if (slashed[key]) revert AlreadySlashed();
        slashed[key] = true;

        amount = (staking.slashableOf(operator) * slashBps) / 10_000;
        if (amount == 0) revert NothingToSlash();
        staking.slash(operator, amount, treasury);
        emit EquivocationSlashed(operator, kind, feedId, round, amount);
    }
}
