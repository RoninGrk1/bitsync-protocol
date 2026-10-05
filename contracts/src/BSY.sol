// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title BitSync (BSY)
/// @notice Fixed-supply institutional utility token for BitSync Protocol.
/// @dev Name "BitSync", symbol "BSY", 8 decimals. Total supply is minted once
///      at construction to `treasury` and can never increase. Holders may burn.
///      MAX_SUPPLY = 42_000_000 * 10**8 base units.
contract BSY is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Maximum and total supply in base units (8 decimals).
    uint256 public constant MAX_SUPPLY = 42_000_000 * 10 ** 8;

    /// @param treasury Recipient of the full genesis supply (timelock / multisig).
    constructor(address treasury) ERC20("BitSync", "BSY") ERC20Permit("BitSync") {
        require(treasury != address(0), "BSY: zero treasury");
        _mint(treasury, MAX_SUPPLY);
    }

    /// @notice BSY uses 8 decimals (Bitcoin-native sat-style base units).
    function decimals() public pure override returns (uint8) {
        return 8;
    }
}
