// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {AllianceToken} from "../src/AllianceToken.sol";

/// @notice Deploys one AllianceToken.
/// @dev Env: NAME, SYMBOL, TREASURY. The signer is whatever `--sender` / `--account`
///      / hardware wallet you pass to forge. This script holds no key.
///      No Builder Code suffix is added to the creation transaction: bytes appended
///      after the constructor arguments would change the creation code that
///      block explorers and Sourcify match against.
contract Deploy is Script {
    function run() external returns (AllianceToken token) {
        string memory name_ = vm.envString("NAME");
        string memory symbol_ = vm.envString("SYMBOL");
        address treasury = vm.envAddress("TREASURY");
        require(treasury != address(0), "TREASURY is zero");

        vm.startBroadcast();
        // Read the nonce inside the broadcast so it is the broadcaster's, not the script contract's.
        address deployer = msg.sender;
        uint64 nonce = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, nonce);
        console2.log("Deployer:          ", deployer);
        console2.log("Deployer nonce:    ", nonce);
        console2.log("Predicted address: ", predicted);

        token = new AllianceToken(name_, symbol_, treasury);
        vm.stopBroadcast();

        console2.log("Deployed address:  ", address(token));
        console2.log("Name:              ", token.name());
        console2.log("Symbol:            ", token.symbol());
        console2.log("Treasury:          ", treasury);
        console2.log("Treasury balance:  ", token.balanceOf(treasury));
        require(address(token) == predicted, "address does not match prediction");
        require(token.balanceOf(treasury) == token.totalSupply(), "treasury does not hold 100%");
    }
}
