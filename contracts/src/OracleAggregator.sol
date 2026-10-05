// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {StakingManager} from "./StakingManager.sol";

/// @title OracleAggregator
/// @notice Accepts threshold ECDSA-quorum reports from registered operators.
/// @dev Upgrade path to BLS aggregate signatures is documented in docs/ARCHITECTURE.md.
///      Domain: EIP712("BitSync Oracle", "1").
contract OracleAggregator is AccessControl, EIP712 {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FEED_ADMIN_ROLE = keccak256("FEED_ADMIN_ROLE");

    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "Report(bytes32 feedId,int256 price,uint256 confidence,uint64 timestamp,uint64 round)"
    );

    struct Report {
        bytes32 feedId;
        int256 price;
        uint256 confidence;
        uint64 timestamp;
        uint64 round;
    }

    struct FeedConfig {
        bool active;
        uint8 decimals;
        uint64 minQuorum; // number of operator signatures required
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
    mapping(bytes32 => mapping(uint64 => bool)) public roundConsumed;

    event FeedUpserted(bytes32 indexed feedId, uint8 decimals, uint64 minQuorum, uint64 maxStaleness);
    event ReportAccepted(
        bytes32 indexed feedId, uint64 round, int256 price, uint256 confidence, uint64 timestamp
    );

    constructor(address staking_, address admin) EIP712("BitSync Oracle", "1") {
        require(staking_ != address(0) && admin != address(0), "Oracle: zero");
        staking = StakingManager(staking_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(FEED_ADMIN_ROLE, admin);
    }

    function upsertFeed(bytes32 feedId, uint8 decimals_, uint64 minQuorum, uint64 maxStaleness)
        external
        onlyRole(FEED_ADMIN_ROLE)
    {
        require(minQuorum > 0, "Oracle: quorum");
        feeds[feedId] =
            FeedConfig({active: true, decimals: decimals_, minQuorum: minQuorum, maxStaleness: maxStaleness});
        emit FeedUpserted(feedId, decimals_, minQuorum, maxStaleness);
    }

    function deactivateFeed(bytes32 feedId) external onlyRole(FEED_ADMIN_ROLE) {
        feeds[feedId].active = false;
    }

    /// @notice EIP-712 digest for a report (matches Rust `Report::digest`).
    function reportDigest(Report calldata report) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REPORT_TYPEHASH,
                    report.feedId,
                    report.price,
                    report.confidence,
                    report.timestamp,
                    report.round
                )
            )
        );
    }

    /// @notice Submit a report with `signatures` from distinct registered operators.
    function submitReport(
        Report calldata report,
        address[] calldata operators,
        bytes[] calldata signatures
    ) external {
        FeedConfig memory cfg = feeds[report.feedId];
        require(cfg.active, "Oracle: inactive");
        require(operators.length == signatures.length, "Oracle: length");
        require(operators.length >= cfg.minQuorum, "Oracle: quorum");
        require(!roundConsumed[report.feedId][report.round], "Oracle: round");
        require(report.timestamp + cfg.maxStaleness >= block.timestamp, "Oracle: stale");
        require(report.timestamp <= block.timestamp + 60, "Oracle: future");

        bytes32 digest = reportDigest(report);
        for (uint256 i = 0; i < operators.length; i++) {
            address op = operators[i];
            require(staking.isOperator(op), "Oracle: not operator");
            for (uint256 j = 0; j < i; j++) {
                require(operators[j] != op, "Oracle: dup");
            }
            require(ECDSA.recover(digest, signatures[i]) == op, "Oracle: bad sig");
        }

        roundConsumed[report.feedId][report.round] = true;
        latest[report.feedId] = RoundData({
            price: report.price,
            confidence: report.confidence,
            timestamp: report.timestamp,
            round: report.round,
            answeredAt: uint64(block.timestamp)
        });
        emit ReportAccepted(
            report.feedId, report.round, report.price, report.confidence, report.timestamp
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
