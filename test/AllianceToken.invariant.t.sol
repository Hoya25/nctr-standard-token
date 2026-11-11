// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AllianceToken} from "../src/AllianceToken.sol";

/// @dev Moves tokens around between a fixed set of actors.
contract Handler is Test {
    AllianceToken public token;
    address[] public actors;

    constructor(AllianceToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approveAndTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract AllianceTokenInvariantTest is Test {
    AllianceToken internal token;
    Handler internal handler;
    address[] internal actors;
    uint256 internal constant SUPPLY = 10_000_000_000 * 1e18;

    function setUp() public {
        for (uint256 i = 0; i < 6; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        token = new AllianceToken("NCTR", "NCTR", actors[0]);
        handler = new Handler(token, actors);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_BalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
    }
}
