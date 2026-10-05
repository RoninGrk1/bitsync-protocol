// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BSY} from "../src/BSY.sol";

contract BSYTest is Test {
    BSY internal token;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        token = new BSY(treasury);
    }

    function test_NameSymbolDecimals() public view {
        assertEq(token.name(), "BitSync");
        assertEq(token.symbol(), "BSY");
        assertEq(token.decimals(), 8);
    }

    function test_TotalSupplyEqualsMax() public view {
        assertEq(token.MAX_SUPPLY(), 42_000_000 * 10 ** 8);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.balanceOf(treasury), token.MAX_SUPPLY());
    }

    function test_NoMintPath() public {
        // BSY exposes no public/external mint. Attempting to call a non-existent
        // mint selector must revert as a fallback miss / no function.
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (bool ok2,) =
            address(token).call(abi.encodeWithSignature("mint(address,uint256,bytes)", address(this), 1, ""));
        assertFalse(ok2);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_BurnReducesSupply() public {
        vm.prank(treasury);
        token.burn(1_000 * 10 ** 8);
        assertEq(token.totalSupply(), token.MAX_SUPPLY() - 1_000 * 10 ** 8);
    }

    function test_Permit() public {
        uint256 pk = 0xA11CE;
        address owner = vm.addr(pk);
        vm.prank(treasury);
        token.transfer(owner, 100 * 10 ** 8);

        address spender = address(0xCAFE);
        uint256 value = 50 * 10 ** 8;
        uint256 nonce = token.nonces(owner);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);
    }

    function testFuzz_TotalSupplyNeverExceedsMax(uint256 burnAmount) public {
        burnAmount = bound(burnAmount, 0, token.totalSupply());
        vm.prank(treasury);
        if (burnAmount > 0) {
            token.burn(burnAmount);
        }
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.totalSupply() + burnAmount, token.MAX_SUPPLY());
    }

    function testFuzz_TransferPreservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != treasury);
        amount = bound(amount, 0, token.balanceOf(treasury));
        uint256 before = token.totalSupply();
        vm.prank(treasury);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), before);
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_RejectZeroTreasury() public {
        vm.expectRevert(bytes("BSY: zero treasury"));
        new BSY(address(0));
    }
}
