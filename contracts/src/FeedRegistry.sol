// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {OracleAggregator} from "./OracleAggregator.sol";

/// @title FeedRegistry
/// @notice Human-readable feed directory mapping base/quote pairs to feedIds.
contract FeedRegistry is AccessControl {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    OracleAggregator public immutable aggregator;
    mapping(bytes32 => bytes32) public pairToFeed; // keccak(base,quote) => feedId
    mapping(bytes32 => string) public feedDescription;

    event FeedRegistered(bytes32 indexed feedId, string base, string quote, string description);

    constructor(address aggregator_, address admin) {
        require(aggregator_ != address(0) && admin != address(0), "Registry: zero");
        aggregator = OracleAggregator(aggregator_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function register(string calldata base, string calldata quote, bytes32 feedId, string calldata description)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        bytes32 key = keccak256(abi.encode(base, quote));
        pairToFeed[key] = feedId;
        feedDescription[feedId] = description;
        emit FeedRegistered(feedId, base, quote, description);
    }

    function getFeedId(string calldata base, string calldata quote) external view returns (bytes32) {
        return pairToFeed[keccak256(abi.encode(base, quote))];
    }

    function latest(string calldata base, string calldata quote)
        external
        view
        returns (int256 price, uint256 confidence, uint64 timestamp, uint64 round, uint64 answeredAt)
    {
        bytes32 feedId = pairToFeed[keccak256(abi.encode(base, quote))];
        return aggregator.latestRoundData(feedId);
    }
}
