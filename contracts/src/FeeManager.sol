// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakeObserver} from "./IStakeObserver.sol";
import {StakingManager} from "./StakingManager.sol";

/// @title FeeManager
/// @notice Consumers pay feed fees in BSY; fees are distributed to bonded stakers with a
///         reward-per-share accumulator (MasterChef-style). Each account is
///         checkpointed by StakingManager hooks on stake / unbond / slash, so:
///         - rewards accrue only to stake that was bonded when the fee was paid
///           (staking right before claiming earns nothing retroactively);
///         - all rounding is downward, so total claims can never exceed deposits.
contract FeeManager is AccessControl, Pausable, ReentrancyGuard, IStakeObserver {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @dev Precision for the accumulator. BSY has 8 decimals and total supply
    ///      4.2e15 base units, so 1e30 keeps per-share dust negligible without
    ///      overflow risk (4.2e15 * 1e30 * 4.2e15 << 2^256).
    uint256 public constant PRECISION = 1e30;

    IERC20 public immutable bsy;
    StakingManager public immutable staking;

    uint256 public feePerRead;
    uint256 public accRewardPerShare;
    /// @notice Fees received while no stake was bonded; folded into the next distribution.
    uint256 public undistributed;
    uint256 public totalDeposited;
    uint256 public totalClaimed;

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pending;

    event FeePaid(address indexed consumer, bytes32 indexed feedId, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event FeeUpdated(uint256 feePerRead);

    error ZeroAddress();
    error OnlyStaking();
    error NothingToClaim();

    constructor(address bsyToken, address staking_, address admin, uint256 feePerRead_) {
        if (bsyToken == address(0) || staking_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        bsy = IERC20(bsyToken);
        staking = StakingManager(staking_);
        feePerRead = feePerRead_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    modifier onlyStaking() {
        if (msg.sender != address(staking)) revert OnlyStaking();
        _;
    }

    // ------------------------------------------------------------------ admin

    function setFee(uint256 feePerRead_) external onlyRole(GOVERNANCE_ROLE) {
        feePerRead = feePerRead_;
        emit FeeUpdated(feePerRead_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // --------------------------------------------------------------- consumer

    function payFee(bytes32 feedId) external nonReentrant whenNotPaused {
        uint256 fee = feePerRead;
        if (fee > 0) {
            bsy.safeTransferFrom(msg.sender, address(this), fee);
            totalDeposited += fee;
            _distribute(fee);
        }
        emit FeePaid(msg.sender, feedId, fee);
    }

    // ----------------------------------------------------------------- staker

    function claim() external nonReentrant whenNotPaused returns (uint256 amount) {
        _settle(msg.sender);
        amount = pending[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pending[msg.sender] = 0;
        totalClaimed += amount;
        bsy.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function pendingRewards(address account) external view returns (uint256) {
        uint256 accrued = (staking.stakedOf(account) * accRewardPerShare) / PRECISION;
        return pending[account] + accrued - rewardDebt[account];
    }

    // ------------------------------------------------------------------ hooks

    function beforeStakeChange(address account) external onlyStaking {
        _settle(account);
    }

    function afterStakeChange(address account) external onlyStaking {
        rewardDebt[account] = (staking.stakedOf(account) * accRewardPerShare) / PRECISION;
    }

    // --------------------------------------------------------------- internal

    function _distribute(uint256 amount) internal {
        uint256 total = staking.totalStaked();
        if (total == 0) {
            undistributed += amount;
            return;
        }
        amount += undistributed;
        undistributed = 0;
        accRewardPerShare += (amount * PRECISION) / total;
    }

    function _settle(address account) internal {
        uint256 accrued = (staking.stakedOf(account) * accRewardPerShare) / PRECISION;
        uint256 debt = rewardDebt[account];
        if (accrued > debt) pending[account] += accrued - debt;
        rewardDebt[account] = accrued;
    }
}
