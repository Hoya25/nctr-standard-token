// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title AllianceToken
/// @notice Fixed-supply ERC-20 with EIP-2612 permit.
/// @dev The whole supply is minted once, to `treasury`, in the constructor.
///      There is no owner, no admin, no mint, no burn, no pause, no fee,
///      no transfer hook and no proxy. Nothing about the token can change
///      after deployment.
contract AllianceToken is ERC20, ERC20Permit {
    /// @notice The total supply, fixed forever: 10,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 1e18;

    error ZeroTreasury();

    constructor(string memory name_, string memory symbol_, address treasury) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (treasury == address(0)) revert ZeroTreasury();
        _mint(treasury, TOTAL_SUPPLY);
    }
}
