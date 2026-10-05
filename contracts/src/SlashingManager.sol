// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {StakingManager} from "./StakingManager.sol";

/// @title SlashingManager
/// @notice Slash operators for provable equivocation (two conflicting signed reports
///         for the same feed+round) or other attested misbehaviour.
contract SlashingManager is AccessControl {
    using ECDSA for bytes32;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    StakingManager public immutable staking;
    address public treasury;
    uint16 public slashBps; // e.g. 500 = 5%
    mapping(bytes32 => bool) public usedEvidence;

    event EquivocationSlashed(
        address indexed operator, bytes32 feedId, uint64 round, uint256 amount
    );
    event ParamsUpdated(address treasury, uint16 slashBps);

    constructor(address staking_, address admin, address treasury_, uint16 slashBps_) {
        require(staking_ != address(0) && admin != address(0) && treasury_ != address(0), "Slash: zero");
        require(slashBps_ <= 10_000, "Slash: bps");
        staking = StakingManager(staking_);
        treasury = treasury_;
        slashBps = slashBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function setParams(address treasury_, uint16 slashBps_) external onlyRole(GOVERNANCE_ROLE) {
        require(treasury_ != address(0) && slashBps_ <= 10_000, "Slash: bad");
        treasury = treasury_;
        slashBps = slashBps_;
        emit ParamsUpdated(treasury_, slashBps_);
    }

    /// @notice Prove equivocation: two distinct digests for same feed+round, both signed by operator.
    function slashEquivocation(
        address operator,
        bytes32 feedId,
        uint64 round,
        bytes32 digestA,
        bytes calldata sigA,
        bytes32 digestB,
        bytes calldata sigB
    ) external {
        require(digestA != digestB, "Slash: same digest");
        require(ECDSA.recover(digestA, sigA) == operator, "Slash: sigA");
        require(ECDSA.recover(digestB, sigB) == operator, "Slash: sigB");

        bytes32 evidenceId = keccak256(abi.encode(operator, feedId, round, digestA, digestB));
        require(!usedEvidence[evidenceId], "Slash: used");
        usedEvidence[evidenceId] = true;

        (uint256 staked,,,) = _stakeOf(operator);
        uint256 amount = (staked * slashBps) / 10_000;
        require(amount > 0, "Slash: zero");
        staking.slash(operator, amount, treasury);
        emit EquivocationSlashed(operator, feedId, round, amount);
    }

    function _stakeOf(address op)
        internal
        view
        returns (uint256 staked, uint256 unbonding, uint64 ready, bool isOp)
    {
        (staked, unbonding, ready, isOp,) = staking.stakes(op);
    }
}
