// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakeObserver} from "./IStakeObserver.sol";

/// @title StakingManager
/// @notice Bond BSY (8-decimal base units) to secure the oracle. Operators must hold
///         at least `minStake` bonded. Unbonding stake remains SLASHABLE until its
///         unbonding period has fully elapsed, so requesting an unbond cannot be used to
///         dodge a pending slash.
/// @dev Roles: GOVERNANCE_ROLE (timelock) sets params and unpauses; GUARDIAN_ROLE
///      (multisig) can pause; SLASHER_ROLE (SlashingManager) can slash. Slashing is
///      intentionally NOT pausable.
contract StakingManager is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    uint256 public constant MAX_UNBONDING_ENTRIES = 16;
    uint256 public constant MAX_OPERATORS = 64;
    uint64 public constant MAX_UNBONDING_PERIOD = 90 days;

    struct Unbonding {
        uint128 amount;
        uint64 releaseAt;
    }

    IERC20 public immutable bsy;
    uint64 public unbondingPeriod;
    uint256 public minStake;

    /// @notice Hook receiving stake-change notifications (FeeManager). Set once.
    IStakeObserver public stakeObserver;

    mapping(address => uint256) public stakedOf;
    mapping(address => bool) public isOperator;
    mapping(address => Unbonding[]) private _unbonding;

    /// @notice Sum of all bonded stake (reward weight denominator).
    uint256 public totalStaked;
    /// @notice Sum of bonded stake of registered operators (oracle quorum denominator).
    uint256 public totalActiveStake;

    address[] private _operators;
    mapping(address => uint256) private _operatorIndex; // 1-based

    event Staked(address indexed account, uint256 amount);
    event UnbondRequested(address indexed account, uint256 amount, uint64 releaseAt);
    event Withdrawn(address indexed account, uint256 amount);
    event OperatorRegistered(address indexed operator);
    event OperatorDeregistered(address indexed operator);
    event Slashed(address indexed account, uint256 fromBonded, uint256 fromUnbonding, address to);
    event ParamsUpdated(uint64 unbondingPeriod, uint256 minStake);
    event StakeObserverSet(address observer);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error AlreadyOperator();
    error NotOperator();
    error TooManyOperators();
    error TooManyUnbondingEntries();
    error NothingToWithdraw();
    error SlashExceedsSlashable();
    error ObserverAlreadySet();
    error InvalidParams();

    constructor(address bsyToken, address admin, uint64 unbondingPeriod_, uint256 minStake_) {
        if (bsyToken == address(0) || admin == address(0)) revert ZeroAddress();
        if (unbondingPeriod_ > MAX_UNBONDING_PERIOD) revert InvalidParams();
        bsy = IERC20(bsyToken);
        unbondingPeriod = unbondingPeriod_;
        minStake = minStake_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin

    function setParams(uint64 unbondingPeriod_, uint256 minStake_)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (unbondingPeriod_ > MAX_UNBONDING_PERIOD) revert InvalidParams();
        unbondingPeriod = unbondingPeriod_;
        minStake = minStake_;
        emit ParamsUpdated(unbondingPeriod_, minStake_);
    }

    /// @notice One-time wiring of the reward observer. Must be set before any stake
    ///         exists so reward accounting starts from a consistent snapshot.
    function setStakeObserver(address observer) external onlyRole(GOVERNANCE_ROLE) {
        if (observer == address(0)) revert ZeroAddress();
        if (address(stakeObserver) != address(0) || totalStaked != 0) revert ObserverAlreadySet();
        stakeObserver = IStakeObserver(observer);
        emit StakeObserverSet(observer);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // --------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 prevActive = _beforeChange(msg.sender);
        bsy.safeTransferFrom(msg.sender, address(this), amount);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _afterChange(msg.sender, prevActive);
        emit Staked(msg.sender, amount);
    }

    function registerOperator() external whenNotPaused {
        if (isOperator[msg.sender]) revert AlreadyOperator();
        if (stakedOf[msg.sender] < minStake || stakedOf[msg.sender] == 0) {
            revert InsufficientStake();
        }
        if (_operators.length >= MAX_OPERATORS) revert TooManyOperators();
        isOperator[msg.sender] = true;
        _operators.push(msg.sender);
        _operatorIndex[msg.sender] = _operators.length;
        totalActiveStake += stakedOf[msg.sender];
        emit OperatorRegistered(msg.sender);
    }

    function deregisterOperator() external {
        if (!isOperator[msg.sender]) revert NotOperator();
        _removeOperator(msg.sender);
    }

    function requestUnbond(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedOf[msg.sender]) revert InsufficientStake();
        Unbonding[] storage q = _unbonding[msg.sender];
        if (q.length >= MAX_UNBONDING_ENTRIES) revert TooManyUnbondingEntries();

        uint256 prevActive = _beforeChange(msg.sender);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        _afterChange(msg.sender, prevActive);

        uint64 releaseAt = uint64(block.timestamp) + unbondingPeriod;
        // forge-lint: disable-next-line(unsafe-typecast)
        q.push(Unbonding({amount: uint128(amount), releaseAt: releaseAt}));
        emit UnbondRequested(msg.sender, amount, releaseAt);
    }

    /// @notice Withdraw all unbonding entries whose period has elapsed.
    function withdraw() external nonReentrant whenNotPaused {
        Unbonding[] storage q = _unbonding[msg.sender];
        uint256 total;
        uint256 i;
        while (i < q.length) {
            if (q[i].releaseAt <= block.timestamp) {
                total += q[i].amount;
                q[i] = q[q.length - 1];
                q.pop();
            } else {
                i++;
            }
        }
        if (total == 0) revert NothingToWithdraw();
        bsy.safeTransfer(msg.sender, total);
        emit Withdrawn(msg.sender, total);
    }

    // -------------------------------------------------------------- slashing

    /// @notice Slash up to `slashableOf(account)`: bonded stake first, then pending
    ///         (not yet released) unbonding entries.
    function slash(address account, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(SLASHER_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > slashableOf(account)) revert SlashExceedsSlashable();

        uint256 fromBonded = amount <= stakedOf[account] ? amount : stakedOf[account];
        if (fromBonded > 0) {
            uint256 prevActive = _beforeChange(account);
            stakedOf[account] -= fromBonded;
            totalStaked -= fromBonded;
            _afterChange(account, prevActive);
        }

        uint256 remaining = amount - fromBonded;
        if (remaining > 0) {
            Unbonding[] storage q = _unbonding[account];
            for (uint256 i = q.length; i > 0 && remaining > 0; i--) {
                Unbonding storage u = q[i - 1];
                if (u.releaseAt <= block.timestamp) continue; // matured: no longer slashable
                uint256 take = remaining < u.amount ? remaining : u.amount;
                // forge-lint: disable-next-line(unsafe-typecast)
                u.amount -= uint128(take);
                remaining -= take;
            }
        }

        bsy.safeTransfer(to, amount);
        emit Slashed(account, fromBonded, amount - fromBonded, to);
    }

    // ----------------------------------------------------------------- views

    /// @notice Bonded stake plus unbonding entries still inside their unbonding period.
    function slashableOf(address account) public view returns (uint256 total) {
        total = stakedOf[account];
        Unbonding[] storage q = _unbonding[account];
        for (uint256 i = 0; i < q.length; i++) {
            if (q[i].releaseAt > block.timestamp) total += q[i].amount;
        }
    }

    function withdrawableOf(address account) external view returns (uint256 total) {
        Unbonding[] storage q = _unbonding[account];
        for (uint256 i = 0; i < q.length; i++) {
            if (q[i].releaseAt <= block.timestamp) total += q[i].amount;
        }
    }

    function unbondingEntries(address account) external view returns (Unbonding[] memory) {
        return _unbonding[account];
    }

    /// @notice Stake counted toward oracle quorum (0 unless a registered operator).
    function activeStakeOf(address account) public view returns (uint256) {
        return isOperator[account] ? stakedOf[account] : 0;
    }

    function operators() external view returns (address[] memory) {
        return _operators;
    }

    function operatorCount() external view returns (uint256) {
        return _operators.length;
    }

    // -------------------------------------------------------------- internal

    function _beforeChange(address account) internal returns (uint256 prevActive) {
        prevActive = activeStakeOf(account);
        if (address(stakeObserver) != address(0)) stakeObserver.beforeStakeChange(account);
    }

    function _afterChange(address account, uint256 prevActive) internal {
        if (isOperator[account] && stakedOf[account] < minStake) {
            // Auto-deregister operators that fall below the minimum. `_removeOperator`
            // subtracts the *current* stake, so restore the pre-change contribution first.
            totalActiveStake = totalActiveStake - prevActive + stakedOf[account];
            _removeOperator(account);
        } else {
            totalActiveStake = totalActiveStake - prevActive + activeStakeOf(account);
        }
        if (address(stakeObserver) != address(0)) stakeObserver.afterStakeChange(account);
    }

    function _removeOperator(address op) internal {
        uint256 idx1 = _operatorIndex[op];
        if (idx1 == 0) revert NotOperator();
        uint256 last = _operators.length - 1;
        if (idx1 - 1 != last) {
            address moved = _operators[last];
            _operators[idx1 - 1] = moved;
            _operatorIndex[moved] = idx1;
        }
        _operators.pop();
        delete _operatorIndex[op];
        isOperator[op] = false;
        totalActiveStake -= stakedOf[op];
        emit OperatorDeregistered(op);
    }
}
