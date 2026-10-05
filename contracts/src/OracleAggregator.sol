// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {StakingManager} from "./StakingManager.sol";
import {Report, Observation, BitSyncTypes} from "./BitSyncTypes.sol";

/// @title OracleAggregator
/// @notice Accepts reports co-signed by registered operators whose combined active
///         stake is STRICTLY greater than 2/3 of total active stake.
/// @dev Signatures must be ordered by strictly ascending signer address (cheap
///      duplicate rejection). Domain: EIP712("BitSync Oracle", "1"). The BLS / FROST
///      upgrade path is documented in docs/ARCHITECTURE.md.
contract OracleAggregator is AccessControl, Pausable, EIP712 {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FEED_ADMIN_ROLE = keccak256("FEED_ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Max tolerated clock skew for report timestamps in the future.
    uint64 public constant MAX_FUTURE_DRIFT = 60;

    struct FeedConfig {
        bool active;
        uint8 decimals;
        uint64 minSigners; // defence-in-depth floor on top of the stake quorum
        uint64 maxStaleness; // seconds
    }

    struct RoundData {
        int256 price;
        uint256 confidence;
        uint64 timestamp;
        uint64 round;
        uint64 answeredAt;
    }

    StakingManager public immutable staking;
    mapping(bytes32 => FeedConfig) public feeds;
    mapping(bytes32 => RoundData) public latest;

    event FeedUpserted(bytes32 indexed feedId, uint8 decimals, uint64 minSigners, uint64 maxStaleness);
    event FeedDeactivated(bytes32 indexed feedId);
    event ReportAccepted(
        bytes32 indexed feedId,
        uint64 indexed round,
        int256 price,
        uint256 confidence,
        uint64 timestamp,
        uint256 signedStake,
        uint256 totalActiveStake
    );

    error ZeroAddress();
    error InvalidConfig();
    error FeedInactive();
    error StaleRound();
    error StaleReport();
    error FutureReport();
    error TooFewSigners();
    error SignersNotAscending();
    error NotActiveOperator(address signer);
    error NoActiveStake();
    error InsufficientStakeQuorum(uint256 signedStake, uint256 totalActiveStake);

    constructor(address staking_, address admin) EIP712("BitSync Oracle", "1") {
        if (staking_ == address(0) || admin == address(0)) revert ZeroAddress();
        staking = StakingManager(staking_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(FEED_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin

    function upsertFeed(bytes32 feedId, uint8 decimals_, uint64 minSigners, uint64 maxStaleness)
        external
        onlyRole(FEED_ADMIN_ROLE)
    {
        if (minSigners == 0 || maxStaleness == 0) revert InvalidConfig();
        feeds[feedId] = FeedConfig({
            active: true, decimals: decimals_, minSigners: minSigners, maxStaleness: maxStaleness
        });
        emit FeedUpserted(feedId, decimals_, minSigners, maxStaleness);
    }

    function deactivateFeed(bytes32 feedId) external onlyRole(FEED_ADMIN_ROLE) {
        feeds[feedId].active = false;
        emit FeedDeactivated(feedId);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- digests

    /// @notice EIP-712 digest of a report (matches Rust `Report::digest` and the TS SDK).
    function reportDigest(Report calldata report) public view returns (bytes32) {
        return _hashTypedDataV4(BitSyncTypes.structHash(report));
    }

    /// @notice EIP-712 digest of an operator observation.
    function observationDigest(Observation calldata observation) public view returns (bytes32) {
        return _hashTypedDataV4(BitSyncTypes.structHash(observation));
    }

    // ------------------------------------------------------------- submission

    /// @notice Submit a report with signatures ordered by ascending signer address.
    function submitReport(Report calldata report, bytes[] calldata signatures)
        external
        whenNotPaused
    {
        FeedConfig memory cfg = feeds[report.feedId];
        if (!cfg.active) revert FeedInactive();
        if (report.round <= latest[report.feedId].round) revert StaleRound();
        if (uint256(report.timestamp) + cfg.maxStaleness < block.timestamp) revert StaleReport();
        if (report.timestamp > block.timestamp + MAX_FUTURE_DRIFT) revert FutureReport();
        if (signatures.length < cfg.minSigners) revert TooFewSigners();

        uint256 total = staking.totalActiveStake();
        if (total == 0) revert NoActiveStake();

        bytes32 digest = reportDigest(report);
        uint256 signedStake;
        address prev;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= prev) revert SignersNotAscending();
            prev = signer;
            uint256 s = staking.activeStakeOf(signer);
            if (s == 0) revert NotActiveOperator(signer);
            signedStake += s;
        }
        // Strictly greater than 2/3 of total active stake.
        if (signedStake * 3 <= total * 2) revert InsufficientStakeQuorum(signedStake, total);

        latest[report.feedId] = RoundData({
            price: report.price,
            confidence: report.confidence,
            timestamp: report.timestamp,
            round: report.round,
            // forge-lint: disable-next-line(unsafe-typecast)
            answeredAt: uint64(block.timestamp)
        });
        emit ReportAccepted(
            report.feedId,
            report.round,
            report.price,
            report.confidence,
            report.timestamp,
            signedStake,
            total
        );
    }

    function latestRoundData(bytes32 feedId)
        external
        view
        returns (int256 price, uint256 confidence, uint64 timestamp, uint64 round, uint64 answeredAt)
    {
        RoundData memory d = latest[feedId];
        return (d.price, d.confidence, d.timestamp, d.round, d.answeredAt);
    }
}
