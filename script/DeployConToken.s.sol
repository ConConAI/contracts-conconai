// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConToken} from "../src/ConToken.sol";

/// @title DeployConToken
/// @author ConConAI
/// @notice Deploys a copy of {ConToken}, minting the full fixed supply to the treasury.
/// @dev    Signing is supplied at runtime by the USER's own wallet (e.g. --ledger, --interactive
///         or an encrypted --account keystore). There are NO hardcoded private keys here.
///
///         $CON is already live on Ethereum mainnet at the canonical token address recorded in
///         `deployments/addresses.json`. On mainnet this script is therefore reference/
///         verification only; downstream contracts must bind to that existing token address.
///         For Sepolia this script deploys a fresh test copy of the token.
contract DeployConToken is Script {
    /// @notice Default treasury used when `TREASURY_ADDRESS` is not set in the environment.
    /// @dev Matches the locked admin/treasury address from `deployments/addresses.json`.
    address internal constant DEFAULT_TREASURY = 0x46bca9FCf2f372e76D9aE265Da725B222F5ac2e0;

    /// @notice Reads the treasury from env (default {DEFAULT_TREASURY}) and broadcasts the deploy.
    /// @return token The freshly deployed {ConToken} instance.
    function run() external returns (ConToken token) {
        address treasury = vm.envOr("TREASURY_ADDRESS", DEFAULT_TREASURY);

        console2.log("Deploying ConToken");
        console2.log("  treasury:", treasury);

        vm.startBroadcast();
        token = new ConToken(treasury);
        vm.stopBroadcast();

        console2.log("  token deployed at:", address(token));
        console2.log("  totalSupply:", token.totalSupply());
        console2.log("  treasury balance:", token.balanceOf(treasury));
    }
}
