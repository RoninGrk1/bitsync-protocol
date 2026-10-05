// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Aggregated oracle report signed by a stake quorum of operators.
struct Report {
    bytes32 feedId;
    int256 price;
    uint256 confidence;
    uint64 timestamp;
    uint64 round;
}

/// @notice A single operator's signed observation (pre-aggregation).
/// @dev Same fields as `Report` but a distinct EIP-712 type, so an honest operator
///      signing one observation and one report for the same round is NOT equivocation.
struct Observation {
    bytes32 feedId;
    int256 price;
    uint256 confidence;
    uint64 timestamp;
    uint64 round;
}

library BitSyncTypes {
    bytes32 internal constant REPORT_TYPEHASH = keccak256(
        "Report(bytes32 feedId,int256 price,uint256 confidence,uint64 timestamp,uint64 round)"
    );
    bytes32 internal constant OBSERVATION_TYPEHASH = keccak256(
        "Observation(bytes32 feedId,int256 price,uint256 confidence,uint64 timestamp,uint64 round)"
    );


    /// @notice Canonical feed id: UTF-8 label left-aligned in bytes32, zero-padded (matches Rust/TS).
    function feedIdFromLabel(string memory label) internal pure returns (bytes32 out) {
        bytes memory b = bytes(label);
        require(b.length != 0 && b.length <= 32, "BitSyncTypes: label");
        assembly ("memory-safe") {
            out := mload(add(b, 32))
        }
    }

    function structHash(Report memory r) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(REPORT_TYPEHASH, r.feedId, r.price, r.confidence, r.timestamp, r.round)
        );
    }

    function structHash(Observation memory o) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(OBSERVATION_TYPEHASH, o.feedId, o.price, o.confidence, o.timestamp, o.round)
        );
    }
}
