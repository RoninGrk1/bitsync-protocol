// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BSY} from "../../src/BSY.sol";
import {BSYPresale} from "../../src/presale/BSYPresale.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BSYPresaleTest is Test {
    uint256 internal constant UNIT = 1e8;
    uint256 internal constant PRICE = 20_000_000; // $0.20 in USD_SCALE
    uint256 internal constant ETH_USD = 2000e8; // $2000, 8 decimals

    BSY internal bsy;
    BSYPresale internal sale;
    MockAggregatorV3 internal feed;
    MockERC20 internal usdc;
    MockERC20 internal usdt;

    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal compliance;
    uint256 internal compliancePk = 0xC0FFEE;
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");

    uint64 internal start;
    uint64 internal end;
    uint64 internal tge;

    function setUp() public {
        compliance = vm.addr(compliancePk);
        vm.warp(1_700_000_000);
        start = uint64(block.timestamp + 1 days);
        end = uint64(block.timestamp + 30 days);
        tge = uint64(block.timestamp + 37 days);

        bsy = new BSY(address(this));
        feed = new MockAggregatorV3(8, int256(ETH_USD));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);

        sale = new BSYPresale(address(bsy), treasury, address(this), address(feed));
        sale.grantRole(sale.GUARDIAN_ROLE(), guardian);
        sale.grantRole(sale.COMPLIANCE_ROLE(), compliance);
        assertFalse(sale.hasRole(sale.COMPLIANCE_ROLE(), address(this)));

        BSYPresale.SaleConfig memory cfg = BSYPresale.SaleConfig({
            start: start,
            end: end,
            tge: tge,
            priceUsdPerBsy: PRICE,
            softCapBsy: 1_000_000 * UNIT,
            minBuyUsd: 10 * UNIT, // $10
            maxBuyUsd: 100_000 * UNIT, // $100k
            tgeUnlockBps: 2_500, // 25%
            vestingDuration: 90 days,
            oracleMaxStale: 1 hours,
            kycRequired: true
        });
        sale.setConfig(cfg);
        sale.setStable(address(usdc), true);
        sale.setStable(address(usdt), true);

        bsy.approve(address(sale), sale.PRESALE_ALLOCATION());
        sale.fund(address(this));

        vm.deal(buyer, 1_000 ether);
        vm.deal(buyer2, 1_000 ether);
        usdc.mint(buyer, 1_000_000e6);
        usdt.mint(buyer, 1_000_000e6);
    }

    function _kyc(address who) internal view returns (bytes memory sig, uint256 deadline, bytes32 jur) {
        deadline = block.timestamp + 1 days;
        jur = keccak256("NON_BLOCKED");
        uint256 nonce = sale.kycNonce(who);
        bytes32 digest = sale.kycDigest(who, nonce, deadline, jur);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(compliancePk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _open() internal {
        vm.warp(start);
        // Keep the ETH/USD feed fresh after warping.
        feed.setAnswer(int256(ETH_USD));
    }

    // ---------------------------------------------------------------- allocation / quotes

    function test_AllocationConstant() public view {
        assertEq(sale.PRESALE_ALLOCATION(), 6_300_000 * UNIT);
        assertEq(bsy.balanceOf(address(sale)), 6_300_000 * UNIT);
        assertTrue(sale.saleFunded());
    }

    function test_QuoteMathEthAndStable() public {
        // $200 of BSY at $0.20 = 1000 BSY
        assertEq(sale.quoteBsy(200 * UNIT), 1000 * UNIT);
        assertEq(sale.quoteUsd(1000 * UNIT), 200 * UNIT);
        // ETH at $2000: $200 => 0.1 ETH = 1e17 wei
        assertEq(sale.quoteEth(1000 * UNIT), 0.1 ether);
    }

    function test_BuyWithEth() public {
        _open();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        uint256 ethIn = sale.quoteEth(1_000 * UNIT);
        vm.prank(buyer);
        sale.buyWithEth{value: ethIn}(1_000 * UNIT, sig, dl, jur);
        (uint256 alloc, uint256 usd,, uint256 ethPaid,,) = sale.purchases(buyer);
        assertEq(alloc, 1_000 * UNIT);
        assertEq(usd, 200 * UNIT);
        assertEq(ethPaid, ethIn);
        assertEq(sale.totalSold(), 1_000 * UNIT);
    }

    function test_BuyWithUsdc() public {
        _open();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        // $200 USDC (6 decimals) => 200e6
        vm.startPrank(buyer);
        usdc.approve(address(sale), 200e6);
        sale.buyWithStable(address(usdc), 200e6, 1_000 * UNIT, sig, dl, jur);
        vm.stopPrank();
        (uint256 alloc,,,,,) = sale.purchases(buyer);
        assertEq(alloc, 1_000 * UNIT);
        assertEq(sale.stablePaid(buyer, address(usdc)), 200e6);
    }

    function test_NeverExceedsAllocation() public {
        // Raise max before sale start (config locks at start).
        BSYPresale.SaleConfig memory cfg = sale.getConfig();
        cfg.maxBuyUsd = type(uint128).max;
        cfg.softCapBsy = 0;
        cfg.kycRequired = false;
        sale.setConfig(cfg);
        _open();

        uint256 rem = sale.remaining();
        uint256 usd = sale.quoteUsd(rem);
        // Paying for rem+1 should hit CapExceeded on the extra
        usdc.mint(buyer, type(uint128).max);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);
        // Buy exact remaining
        uint256 stableAmt = usd / 100; // USD_SCALE 1e8 -> USDC 1e6 is /100
        // usd is 1e8; usdc 6dp => amount = usd / 1e2
        sale.buyWithStable(address(usdc), usd / 100, rem, "", 0, bytes32(0));
        assertEq(sale.totalSold(), rem);
        assertEq(sale.remaining(), 0);
        // Sale no longer active once sold out.
        assertFalse(sale.saleActive());
        vm.expectRevert(BSYPresale.SaleNotActive.selector);
        sale.buyWithStable(address(usdc), 1e6, 0, "", 0, bytes32(0));
        vm.stopPrank();
    }

    function testFuzz_NeverSellsMoreThanAllocation(uint256 usdSeed, uint8 nBuys) public {
        BSYPresale.SaleConfig memory cfg = sale.getConfig();
        cfg.maxBuyUsd = type(uint128).max;
        cfg.minBuyUsd = 1;
        cfg.softCapBsy = 0;
        cfg.kycRequired = false;
        sale.setConfig(cfg);
        _open();

        nBuys = uint8(bound(nBuys, 1, 20));
        address who = buyer;
        usdc.mint(who, type(uint128).max);
        vm.startPrank(who);
        usdc.approve(address(sale), type(uint256).max);
        for (uint256 i = 0; i < nBuys; i++) {
            uint256 rem = sale.remaining();
            if (rem == 0) break;
            uint256 usd = bound(uint256(keccak256(abi.encode(usdSeed, i))), 1, 50_000 * UNIT);
            uint256 bsyOut = sale.quoteBsy(usd);
            if (bsyOut == 0) continue;
            if (bsyOut > rem) {
                usd = sale.quoteUsd(rem);
                bsyOut = rem;
            }
            uint256 usdcAmt = usd / 100;
            if (usdcAmt == 0) continue;
            sale.buyWithStable(address(usdc), usdcAmt, 0, "", 0, bytes32(0));
        }
        vm.stopPrank();
        assertLe(sale.totalSold(), sale.PRESALE_ALLOCATION());
        assertLe(bsy.balanceOf(address(sale)), bsy.MAX_SUPPLY());
    }

    function test_StaleOracleRejected() public {
        _open();
        feed.setUpdatedAt(block.timestamp - 2 hours);
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        vm.prank(buyer);
        vm.expectRevert(BSYPresale.StaleOracle.selector);
        sale.buyWithEth{value: 1 ether}(0, sig, dl, jur);
    }

    function test_KycRequiredAndInvalidRejected() public {
        _open();
        vm.prank(buyer);
        vm.expectRevert(BSYPresale.InvalidKyc.selector);
        sale.buyWithEth{value: 1 ether}(0, bytes(""), block.timestamp + 1, bytes32(0));
    }

    function test_PauseBlocksBuy() public {
        _open();
        vm.prank(guardian);
        sale.pause();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sale.buyWithEth{value: 1 ether}(0, sig, dl, jur);
    }

    function test_SoftCapRefundEth() public {
        _open();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        uint256 ethIn = sale.quoteEth(100 * UNIT); // well under soft cap
        vm.prank(buyer);
        sale.buyWithEth{value: ethIn}(100 * UNIT, sig, dl, jur);

        vm.warp(end);
        sale.finalize();
        assertTrue(sale.softCapFailed());

        uint256 before = buyer.balance;
        vm.prank(buyer);
        sale.claimRefund();
        assertEq(buyer.balance, before + ethIn);
        (uint256 alloc,,,, bool voided, bool ethRefunded) = sale.purchases(buyer);
        assertEq(alloc, 0);
        assertTrue(voided);
        assertTrue(ethRefunded);
    }

    function test_VestingClaim() public {
        // Disable soft cap so we can finalize as success with small buy
        BSYPresale.SaleConfig memory cfg = sale.getConfig();
        cfg.softCapBsy = 0;
        cfg.kycRequired = false;
        sale.setConfig(cfg);

        _open();
        uint256 ethIn = sale.quoteEth(1_000 * UNIT);
        vm.prank(buyer);
        sale.buyWithEth{value: ethIn}(1_000 * UNIT, "", 0, bytes32(0));

        vm.warp(end);
        sale.finalize();
        assertFalse(sale.softCapFailed());

        vm.warp(tge);
        uint256 tgeAmt = (1_000 * UNIT * 2_500) / 10_000; // 250
        vm.prank(buyer);
        sale.claim();
        assertEq(bsy.balanceOf(buyer), tgeAmt);

        vm.warp(tge + 45 days); // half of 90d vest of remainder
        uint256 halfRem = ((1_000 * UNIT - tgeAmt) * 45 days) / 90 days;
        vm.prank(buyer);
        sale.claim();
        assertEq(bsy.balanceOf(buyer), tgeAmt + halfRem);

        vm.warp(tge + 90 days);
        vm.prank(buyer);
        sale.claim();
        assertEq(bsy.balanceOf(buyer), 1_000 * UNIT);
    }

    function test_WithdrawProceedsToTreasury() public {
        BSYPresale.SaleConfig memory cfg = sale.getConfig();
        cfg.softCapBsy = 0;
        cfg.kycRequired = false;
        sale.setConfig(cfg);
        _open();
        vm.prank(buyer);
        sale.buyWithEth{value: 1 ether}(0, "", 0, bytes32(0));
        vm.warp(end);
        sale.finalize();
        uint256 before = treasury.balance;
        sale.withdrawEth();
        assertEq(treasury.balance, before + 1 ether);
    }

    function test_RoundingNeverFavoursBuyerBeyondOneBaseUnit(uint256 usd) public {
        usd = bound(usd, 1, 1_000_000 * UNIT);
        uint256 bsyOut = sale.quoteBsy(usd);
        // bsyOut * price / USD_SCALE <= usd  (floor)
        assertLe((bsyOut * PRICE) / UNIT, usd);
        // Adding 1 base unit of BSY would require >= usd (ceil property of quoteUsd)
        if (bsyOut < sale.PRESALE_ALLOCATION()) {
            uint256 usdForPlus1 = sale.quoteUsd(bsyOut + 1);
            assertGe(usdForPlus1, usd);
        }
    }

    function test_MinMaxWallet() public {
                BSYPresale.SaleConfig memory cfg = sale.getConfig();
        cfg.kycRequired = false;
        sale.setConfig(cfg);
        _open();
        // 0.001 ETH at $2000 = $2 < $10 min
        vm.prank(buyer);
        vm.expectRevert(BSYPresale.BelowMin.selector);
        sale.buyWithEth{value: 0.001 ether}(0, "", 0, bytes32(0));
    }
    /// BSY-C1 regression: mixed ETH+stable soft-cap refund returns both assets.
    function test_Audit_MixedPaymentRefundBothAssets() public {
        _open();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        vm.startPrank(buyer);
        sale.buyWithEth{value: 1 ether}(0, sig, dl, jur);
        (sig, dl, jur) = _kyc(buyer); // new nonce after first buy consumed one
        usdc.approve(address(sale), 1_000e6);
        sale.buyWithStable(address(usdc), 1_000e6, 0, sig, dl, jur);
        vm.stopPrank();

        vm.warp(end);
        sale.finalize();
        assertTrue(sale.softCapFailed());

        uint256 ethBefore = buyer.balance;
        uint256 usdcBefore = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        sale.claimRefundStable(address(usdc));
        sale.claimRefund(); // ETH still claimable after stable refund
        vm.stopPrank();
        assertEq(buyer.balance, ethBefore + 1 ether);
        assertEq(usdc.balanceOf(buyer), usdcBefore + 1_000e6);
        assertEq(address(sale).balance, 0);
        vm.expectRevert(BSYPresale.SoftCapFailedPath.selector);
        sale.withdrawEth();
    }

    /// BSY-H2 regression: setConfig reverts once the sale has started.
    function test_Audit_ConfigLockedAfterStart() public {
        _open();
        BSYPresale.SaleConfig memory c = sale.getConfig();
        c.softCapBsy = c.softCapBsy + 1;
        vm.expectRevert(BSYPresale.ConfigLocked.selector);
        sale.setConfig(c);
    }

    /// BSY-C2/M7: KYC nonce is consumed; replaying the same sig fails.
    function test_Audit_KycNonceConsumed() public {
        _open();
        (bytes memory sig, uint256 dl, bytes32 jur) = _kyc(buyer);
        uint256 ethIn = sale.quoteEth(1_000 * UNIT);
        vm.prank(buyer);
        sale.buyWithEth{value: ethIn}(1_000 * UNIT, sig, dl, jur);
        vm.prank(buyer);
        vm.expectRevert(BSYPresale.InvalidKyc.selector);
        sale.buyWithEth{value: ethIn}(0, sig, dl, jur);
    }

}
