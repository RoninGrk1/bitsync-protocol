// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakingManager} from "./StakingManager.sol";

/// @title FeeManager
/// @notice Consumers pay feed fees in BSY; accrued fees are claimable by stakers
///         proportional to their bonded stake at claim time (simple pro-rata model).
contract FeeManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    IERC20 public immutable bsy;
    StakingManager public immutable staking;
    uint256 public feePerRead; // BSY base units
    uint256 public totalAccrued;
    mapping(address => uint256) public accrued;

    event FeePaid(address indexed consumer, bytes32 indexed feedId, uint256 amount);
    event Claimed(address indexed staker, uint256 amount);
    event FeeUpdated(uint256 feePerRead);

    constructor(address bsyToken, address staking_, address admin, uint256 feePerRead_) {
        require(bsyToken != address(0) && staking_ != address(0) && admin != address(0), "Fee: zero");
        bsy = IERC20(bsyToken);
        staking = StakingManager(staking_);
        feePerRead = feePerRead_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function setFee(uint256 feePerRead_) external onlyRole(GOVERNANCE_ROLE) {
        feePerRead = feePerRead_;
        emit FeeUpdated(feePerRead_);
    }

    /// @notice Pay the read fee for `feedId`. Credits the fee pool for later pro-rata claims.
    function payFee(bytes32 feedId) external nonReentrant {
        uint256 fee = feePerRead;
        if (fee == 0) {
            emit FeePaid(msg.sender, feedId, 0);
            return;
        }
        bsy.safeTransferFrom(msg.sender, address(this), fee);
        totalAccrued += fee;
        emit FeePaid(msg.sender, feedId, fee);
    }

    /// @notice Claim a share of the fee pool proportional to current stake / total operator stake.
    /// @dev Simplified model for v0; production should use reward-per-token snapshots.
    function claim() external nonReentrant {
        (uint256 staked,,,) = _stakeOf(msg.sender);
        require(staked > 0, "Fee: no stake");
        uint256 totalStake = _totalOperatorStake();
        require(totalStake > 0, "Fee: no total");
        uint256 share = (totalAccrued * staked) / totalStake;
        uint256 already = accrued[msg.sender];
        require(share > already, "Fee: nothing");
        uint256 amount = share - already;
        accrued[msg.sender] = share;
        bsy.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _stakeOf(address op)
        internal
        view
        returns (uint256 staked, uint256 unbonding, uint64 ready, bool isOp)
    {
        (staked, unbonding, ready, isOp,) = staking.stakes(op);
    }

    function _totalOperatorStake() internal view returns (uint256 total) {
        uint256 n = staking.operatorCount();
        for (uint256 i = 0; i < n; i++) {
            address op = staking.operators(i);
            (uint256 staked,,,,) = staking.stakes(op);
            total += staked;
        }
    }
}
