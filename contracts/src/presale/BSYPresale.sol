// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @title BSYPresale
/// @notice Fixed 6.3M BSY (15% of 42M) sale. Buys with ETH (Chainlink-style USD feed)
///         or allowlisted stables. Optional soft-cap refunds, EIP-712 KYC gate,
///         TGE claim with linear vesting. Never mints — treasury funds the allocation.
contract BSYPresale is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    uint256 public constant PRESALE_ALLOCATION = 6_300_000 * 10 ** 8;
    uint256 public constant USD_SCALE = 1e8;
    bytes32 public constant KYC_TYPEHASH =
        keccak256("KycApproval(address buyer,uint256 nonce,uint256 deadline,bytes32 jurisdictionHash)");

    struct SaleConfig {
        uint64 start;
        uint64 end;
        uint64 tge;
        uint256 priceUsdPerBsy; // USD_SCALE, e.g. $0.20 = 20_000_000
        uint256 softCapBsy; // 0 disables soft-cap / refunds
        uint256 minBuyUsd;
        uint256 maxBuyUsd;
        uint16 tgeUnlockBps;
        uint64 vestingDuration;
        uint64 oracleMaxStale;
        bool kycRequired;
    }

    struct Purchase {
        uint256 bsyAllocated;
        uint256 usdPaid;
        uint256 claimed;
        uint256 ethPaid;
        bool allocationVoided; // BSY allocation reversed on soft-cap refund (once)
        bool ethRefunded; // ETH proceeds returned (independent of stables)
    }

    IERC20 public immutable bsy;
    address public treasury;
    IAggregatorV3 public ethUsdFeed;
    SaleConfig public config;

    uint256 public totalSold;
    uint256 public totalUsdRaised;
    uint256 public totalClaimed;
    bool public finalized;
    bool public softCapFailed;
    bool public saleFunded;

    mapping(address => bool) public allowedStable;
    mapping(address => uint8) public stableDecimals;
    mapping(address => Purchase) public purchases;
    mapping(address => mapping(address => uint256)) public stablePaid;
    /// @notice Per-buyer KYC approval nonce (included in EIP-712; increments on use).
    mapping(address => uint256) public kycNonce;

    event SaleConfigured(SaleConfig config);
    event StableAllowlisted(address indexed token, uint8 decimals, bool allowed);
    event EthFeedUpdated(address feed);
    event TreasuryUpdated(address treasury);
    event SaleFunded(uint256 amount);
    event Purchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 usdPaid,
        uint256 bsyAmount
    );
    event Refunded(address indexed buyer, uint256 bsyVoided, uint256 ethRefunded);
    event StableRefunded(address indexed buyer, address indexed token, uint256 amount);
    event Claimed(address indexed buyer, uint256 amount);
    event ProceedsWithdrawn(address indexed to, address indexed token, uint256 amount);
    event UnsoldReturned(address indexed to, uint256 amount);
    event Finalized(bool softCapFailed_, uint256 totalSold_);

    error ZeroAddress();
    error InvalidConfig();
    error AlreadyFunded();
    error SaleNotActive();
    error SaleNotEnded();
    error AlreadyFinalized();
    error SoftCapNotFailed();
    error SoftCapFailedPath();
    error NothingToRefund();
    error NothingToClaim();
    error CapExceeded();
    error BelowMin();
    error AboveMax();
    error StableNotAllowed();
    error StaleOracle();
    error BadOracle();
    error InvalidKyc();
    error ZeroAmount();
    error TransferFailed();
    error Slippage();
    error ConfigLocked();
    error BadKycNonce();

    constructor(address bsy_, address treasury_, address admin, address ethUsdFeed_)
        EIP712("BitSync Presale", "1")
    {
        if (bsy_ == address(0) || treasury_ == address(0) || admin == address(0)) revert ZeroAddress();
        bsy = IERC20(bsy_);
        treasury = treasury_;
        ethUsdFeed = IAggregatorV3(ethUsdFeed_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        // COMPLIANCE_ROLE is granted explicitly to the designated signer (see Deploy.s.sol).
    }

    // ------------------------------------------------------------------ admin

    function setConfig(SaleConfig calldata c) external onlyRole(GOVERNANCE_ROLE) {
        if (finalized) revert AlreadyFinalized();
        // Freeze economic terms once the configured start time has been reached.
        if (config.start != 0 && block.timestamp >= config.start) revert ConfigLocked();
        if (c.start == 0 || c.end <= c.start || c.tge < c.end) revert InvalidConfig();
        if (c.priceUsdPerBsy == 0 || c.maxBuyUsd < c.minBuyUsd) revert InvalidConfig();
        if (c.tgeUnlockBps > 10_000 || c.softCapBsy > PRESALE_ALLOCATION) revert InvalidConfig();
        if (c.oracleMaxStale == 0) revert InvalidConfig();
        config = c;
        emit SaleConfigured(c);
    }

    function setStable(address token, bool allowed) external onlyRole(GOVERNANCE_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        uint8 dec = IERC20Metadata(token).decimals();
        allowedStable[token] = allowed;
        stableDecimals[token] = dec;
        emit StableAllowlisted(token, dec, allowed);
    }

    function setEthFeed(address feed) external onlyRole(GOVERNANCE_ROLE) {
        if (feed == address(0)) revert ZeroAddress();
        ethUsdFeed = IAggregatorV3(feed);
        emit EthFeedUpdated(feed);
    }

    function setTreasury(address treasury_) external onlyRole(GOVERNANCE_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function fund(address from) external onlyRole(GOVERNANCE_ROLE) {
        if (saleFunded) revert AlreadyFunded();
        bsy.safeTransferFrom(from, address(this), PRESALE_ALLOCATION);
        saleFunded = true;
        emit SaleFunded(PRESALE_ALLOCATION);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ----------------------------------------------------------------- views

    function getConfig() external view returns (SaleConfig memory) {
        return config;
    }

    function remaining() public view returns (uint256) {
        return PRESALE_ALLOCATION - totalSold;
    }

    function saleActive() public view returns (bool) {
        SaleConfig memory c = config;
        return saleFunded && !finalized && block.timestamp >= c.start && block.timestamp < c.end
            && totalSold < PRESALE_ALLOCATION;
    }

    /// @dev Floor: buyer never receives more BSY than USD justifies (≤1 base unit favour to seller).
    function quoteBsy(uint256 usdAmount) public view returns (uint256) {
        if (usdAmount == 0 || config.priceUsdPerBsy == 0) return 0;
        return (usdAmount * USD_SCALE) / config.priceUsdPerBsy;
    }

    /// @dev Ceil: buyer never underpays USD for a target BSY amount.
    function quoteUsd(uint256 bsyAmount) public view returns (uint256) {
        if (bsyAmount == 0 || config.priceUsdPerBsy == 0) return 0;
        return (bsyAmount * config.priceUsdPerBsy + USD_SCALE - 1) / USD_SCALE;
    }

    function quoteEth(uint256 bsyAmount) public view returns (uint256 ethWei) {
        uint256 usd = quoteUsd(bsyAmount);
        (uint256 price, uint8 dec) = _ethUsd();
        ethWei =
            (usd * 1e18 * (10 ** uint256(dec)) + (price * USD_SCALE) - 1) / (price * USD_SCALE);
    }

    function claimableOf(address account) public view returns (uint256) {
        if (!finalized || softCapFailed) return 0;
        SaleConfig memory c = config;
        if (block.timestamp < c.tge) return 0;
        Purchase memory p = purchases[account];
        if (p.allocationVoided || p.bsyAllocated == 0) return 0;
        uint256 vested = _vestedAmount(p.bsyAllocated, c);
        return vested - p.claimed;
    }

    function kycDigest(address buyer, uint256 nonce, uint256 deadline, bytes32 jurisdictionHash)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(KYC_TYPEHASH, buyer, nonce, deadline, jurisdictionHash))
        );
    }

    // ------------------------------------------------------------------- buy

    function buyWithEth(uint256 minBsyOut, bytes calldata kycSig, uint256 kycDeadline, bytes32 jurisdictionHash)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (msg.value == 0) revert ZeroAmount();
        _checkKyc(msg.sender, kycSig, kycDeadline, jurisdictionHash);
        (uint256 price, uint8 dec) = _ethUsd();
        uint256 usdPaid = (msg.value * price * USD_SCALE) / (1e18 * (10 ** uint256(dec)));
        uint256 bsyAmount = quoteBsy(usdPaid);
        if (bsyAmount < minBsyOut) revert Slippage();
        _allocate(msg.sender, bsyAmount, usdPaid);
        purchases[msg.sender].ethPaid += msg.value;
        emit Purchased(msg.sender, address(0), msg.value, usdPaid, bsyAmount);
    }

    function buyWithStable(
        address token,
        uint256 amount,
        uint256 minBsyOut,
        bytes calldata kycSig,
        uint256 kycDeadline,
        bytes32 jurisdictionHash
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!allowedStable[token]) revert StableNotAllowed();
        _checkKyc(msg.sender, kycSig, kycDeadline, jurisdictionHash);
        uint8 dec = stableDecimals[token];
        uint256 usdPaid =
            dec >= 8 ? amount / (10 ** (dec - 8)) : amount * (10 ** (8 - dec));
        uint256 bsyAmount = quoteBsy(usdPaid);
        if (bsyAmount < minBsyOut) revert Slippage();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _allocate(msg.sender, bsyAmount, usdPaid);
        stablePaid[msg.sender][token] += amount;
        emit Purchased(msg.sender, token, amount, usdPaid, bsyAmount);
    }

    function _allocate(address buyer, uint256 bsyAmount, uint256 usdPaid) internal {
        if (!saleActive()) revert SaleNotActive();
        if (bsyAmount == 0) revert ZeroAmount();
        if (bsyAmount > remaining()) revert CapExceeded();
        SaleConfig memory c = config;
        if (usdPaid < c.minBuyUsd) revert BelowMin();
        Purchase storage p = purchases[buyer];
        if (p.usdPaid + usdPaid > c.maxBuyUsd) revert AboveMax();
        p.bsyAllocated += bsyAmount;
        p.usdPaid += usdPaid;
        totalSold += bsyAmount;
        totalUsdRaised += usdPaid;
    }

    // ------------------------------------------------------ finalize / refund / claim

    function finalize() external {
        if (block.timestamp < config.end) revert SaleNotEnded();
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        if (config.softCapBsy > 0 && totalSold < config.softCapBsy) softCapFailed = true;
        emit Finalized(softCapFailed, totalSold);
    }

    function claimRefund() external nonReentrant {
        if (!finalized || !softCapFailed) revert SoftCapNotFailed();
        Purchase storage p = purchases[msg.sender];
        if (p.ethRefunded || p.ethPaid == 0) revert NothingToRefund();
        uint256 ethAmt = p.ethPaid;
        p.ethPaid = 0;
        p.ethRefunded = true;
        uint256 bsyVoided = _voidAllocation(p);
        (bool ok,) = msg.sender.call{value: ethAmt}("");
        if (!ok) revert TransferFailed();
        emit Refunded(msg.sender, bsyVoided, ethAmt);
    }

    function claimRefundStable(address token) external nonReentrant {
        if (!finalized || !softCapFailed) revert SoftCapNotFailed();
        uint256 amt = stablePaid[msg.sender][token];
        if (amt == 0) revert NothingToRefund();
        stablePaid[msg.sender][token] = 0;
        Purchase storage p = purchases[msg.sender];
        uint256 bsyVoided = _voidAllocation(p);
        if (bsyVoided > 0) emit Refunded(msg.sender, bsyVoided, 0);
        IERC20(token).safeTransfer(msg.sender, amt);
        emit StableRefunded(msg.sender, token, amt);
    }

    /// @dev Reverse BSY allocation at most once across mixed ETH/stable refunds.
    function _voidAllocation(Purchase storage p) internal returns (uint256 bsyVoided) {
        if (p.allocationVoided || p.bsyAllocated == 0) return 0;
        bsyVoided = p.bsyAllocated;
        totalSold -= bsyVoided;
        p.bsyAllocated = 0;
        p.allocationVoided = true;
    }

    function claim() external nonReentrant whenNotPaused {
        if (!finalized) revert SaleNotEnded();
        if (softCapFailed) revert SoftCapFailedPath();
        if (block.timestamp < config.tge) revert SaleNotEnded();
        Purchase storage p = purchases[msg.sender];
        if (p.allocationVoided || p.bsyAllocated == 0) revert NothingToClaim();
        uint256 vested = _vestedAmount(p.bsyAllocated, config);
        uint256 amount = vested - p.claimed;
        if (amount == 0) revert NothingToClaim();
        p.claimed += amount;
        totalClaimed += amount;
        bsy.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _vestedAmount(uint256 total, SaleConfig memory c) internal view returns (uint256) {
        uint256 tgeAmt = (total * c.tgeUnlockBps) / 10_000;
        if (c.vestingDuration == 0) return total;
        if (block.timestamp <= c.tge) return tgeAmt;
        uint256 elapsed = block.timestamp - c.tge;
        if (elapsed >= c.vestingDuration) return total;
        return tgeAmt + ((total - tgeAmt) * elapsed) / c.vestingDuration;
    }

    // -------------------------------------------------------------- proceeds

    function withdrawEth() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!finalized || softCapFailed) revert SoftCapFailedPath();
        uint256 bal = address(this).balance;
        (bool ok,) = treasury.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit ProceedsWithdrawn(treasury, address(0), bal);
    }

    function withdrawStable(address token) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!finalized || softCapFailed) revert SoftCapFailedPath();
        if (token == address(bsy)) revert InvalidConfig();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(treasury, bal);
        emit ProceedsWithdrawn(treasury, token, bal);
    }

    /// @notice Return unsold + (if soft-cap failed) all remaining BSY to treasury.
    function returnUnsoldBsy() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!finalized) revert SaleNotEnded();
        uint256 locked = softCapFailed ? 0 : (totalSold - totalClaimed);
        uint256 bal = bsy.balanceOf(address(this));
        uint256 amount = bal - locked;
        bsy.safeTransfer(treasury, amount);
        emit UnsoldReturned(treasury, amount);
    }

    // ---------------------------------------------------------------- helpers

    function _checkKyc(address buyer, bytes calldata sig, uint256 deadline, bytes32 jurisdictionHash)
        internal
    {
        if (!config.kycRequired) return;
        if (block.timestamp > deadline || sig.length != 65) revert InvalidKyc();
        uint256 nonce = kycNonce[buyer];
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(KYC_TYPEHASH, buyer, nonce, deadline, jurisdictionHash))
        );
        if (!hasRole(COMPLIANCE_ROLE, ECDSA.recover(digest, sig))) revert InvalidKyc();
        // Consume nonce so the same approval cannot be replayed (BSY-C2 / M7).
        kycNonce[buyer] = nonce + 1;
    }

    function _ethUsd() internal view returns (uint256 price, uint8 dec) {
        if (address(ethUsdFeed) == address(0)) revert BadOracle();
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadOracle();
        if (block.timestamp < updatedAt || block.timestamp - updatedAt > config.oracleMaxStale) {
            revert StaleOracle();
        }
        return (uint256(answer), ethUsdFeed.decimals());
    }

    receive() external payable {}
}
