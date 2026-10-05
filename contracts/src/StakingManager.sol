// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingManager
/// @notice Stake BSY to secure the oracle set; register as an operator.
/// @dev Amounts are in BSY base units (8 decimals). Unbonding period applies.
contract StakingManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    IERC20 public immutable bsy;
    uint64 public unbondingPeriod;
    uint256 public minStake;

    struct StakeInfo {
        uint256 staked;
        uint256 unbonding;
        uint64 unbondReadyAt;
        bool isOperator;
        bytes blsPubkey; // reserved for BLS upgrade path; unused by ECDSA quorum today
    }

    mapping(address => StakeInfo) public stakes;
    address[] public operators;
    mapping(address => uint256) private _operatorIndex; // 1-based; 0 = absent

    event Staked(address indexed operator, uint256 amount);
    event UnbondRequested(address indexed operator, uint256 amount, uint64 readyAt);
    event Unbonded(address indexed operator, uint256 amount);
    event OperatorRegistered(address indexed operator);
    event OperatorDeregistered(address indexed operator);
    event Slashed(address indexed operator, uint256 amount, address to);
    event ParamsUpdated(uint64 unbondingPeriod, uint256 minStake);

    constructor(address bsyToken, address admin, uint64 unbondingPeriod_, uint256 minStake_) {
        require(bsyToken != address(0) && admin != address(0), "Staking: zero");
        bsy = IERC20(bsyToken);
        unbondingPeriod = unbondingPeriod_;
        minStake = minStake_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function setParams(uint64 unbondingPeriod_, uint256 minStake_)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        unbondingPeriod = unbondingPeriod_;
        minStake = minStake_;
        emit ParamsUpdated(unbondingPeriod_, minStake_);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Staking: zero amount");
        bsy.safeTransferFrom(msg.sender, address(this), amount);
        stakes[msg.sender].staked += amount;
        emit Staked(msg.sender, amount);
    }

    function registerOperator(bytes calldata blsPubkey) external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.staked >= minStake, "Staking: below min");
        require(!s.isOperator, "Staking: already");
        s.isOperator = true;
        s.blsPubkey = blsPubkey;
        operators.push(msg.sender);
        _operatorIndex[msg.sender] = operators.length; // 1-based
        emit OperatorRegistered(msg.sender);
    }

    function requestUnbond(uint256 amount) external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        require(amount > 0 && amount <= s.staked, "Staking: bad amount");
        if (s.isOperator && s.staked - amount < minStake) {
            _removeOperator(msg.sender);
        }
        s.staked -= amount;
        s.unbonding += amount;
        s.unbondReadyAt = uint64(block.timestamp) + unbondingPeriod;
        emit UnbondRequested(msg.sender, amount, s.unbondReadyAt);
    }

    function completeUnbond() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        require(s.unbonding > 0, "Staking: none");
        require(block.timestamp >= s.unbondReadyAt, "Staking: not ready");
        uint256 amount = s.unbonding;
        s.unbonding = 0;
        s.unbondReadyAt = 0;
        bsy.safeTransfer(msg.sender, amount);
        emit Unbonded(msg.sender, amount);
    }

    /// @notice Slash staked (not unbonding) BSY. Called by SlashingManager.
    function slash(address operator, uint256 amount, address to)
        external
        onlyRole(SLASHER_ROLE)
        nonReentrant
    {
        StakeInfo storage s = stakes[operator];
        require(amount > 0 && amount <= s.staked, "Staking: slash amount");
        s.staked -= amount;
        if (s.isOperator && s.staked < minStake) {
            _removeOperator(operator);
        }
        bsy.safeTransfer(to, amount);
        emit Slashed(operator, amount, to);
    }

    function operatorCount() external view returns (uint256) {
        return operators.length;
    }

    function isOperator(address account) external view returns (bool) {
        return stakes[account].isOperator;
    }

    function _removeOperator(address op) internal {
        uint256 idx1 = _operatorIndex[op];
        require(idx1 != 0, "Staking: not op");
        uint256 idx = idx1 - 1;
        uint256 last = operators.length - 1;
        if (idx != last) {
            address moved = operators[last];
            operators[idx] = moved;
            _operatorIndex[moved] = idx + 1;
        }
        operators.pop();
        delete _operatorIndex[op];
        stakes[op].isOperator = false;
        emit OperatorDeregistered(op);
    }
}
