// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Presale} from "../src/Presale.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployPresale
/// @author ConConAI
/// @notice Deploys {Presale}, reading the immutable config (token, admin, stablecoins, oracle) from
///         `deployments/addresses.json` for the target network.
/// @dev    Signing is supplied at runtime by the USER's own wallet (e.g. --ledger, --interactive or
///         an encrypted --account keystore). There are NO hardcoded private keys here, and this
///         script does NOT deploy a token — it binds to the existing $CON address from the config.
///
///         After deploy, the treasury must transfer up to 50,000,000 $CON into the presale so that
///         claims can be paid out (a user action with their own wallet), and the deployed presale
///         address should be written back into `deployments/addresses.json`.
contract DeployPresale is Script {
    error AddressNotConfigured(string field);

    /// @notice Reads config from `deployments/addresses.json` and broadcasts the presale deploy.
    /// @return presale The deployed {Presale} instance.
    function run() external returns (Presale presale) {
        string memory network = _network();
        string memory json = vm.readFile("deployments/addresses.json");

        address token = _readAddress(json, network, "token");
        address admin = _readAddress(json, network, "admin");
        address usdc = _readAddress(json, network, "usdc");
        address usdt = _readAddress(json, network, "usdt");
        address ethUsdFeed = _readAddress(json, network, "ethUsdFeed");

        console2.log("Deploying Presale");
        console2.log("  network:", network);
        console2.log("  conToken:", token);
        console2.log("  usdc:", usdc);
        console2.log("  usdt:", usdt);
        console2.log("  ethUsdFeed:", ethUsdFeed);
        console2.log("  treasury/admin:", admin);

        vm.startBroadcast();
        presale = new Presale(IERC20(token), IERC20(usdc), IERC20(usdt), IAggregatorV3(ethUsdFeed), admin);
        vm.stopBroadcast();

        console2.log("  presale deployed at:", address(presale));
        console2.log("  NEXT: treasury funds the presale with up to 50,000,000 CON, then record");
        console2.log("        this presale address under the network in deployments/addresses.json");
    }

    /// @dev Resolves the network key from the `NETWORK` env var, falling back to the chain id.
    function _network() internal view returns (string memory) {
        string memory fromEnv = vm.envOr("NETWORK", string(""));
        if (bytes(fromEnv).length != 0) return fromEnv;
        if (block.chainid == 1) return "mainnet";
        if (block.chainid == 11_155_111) return "sepolia";
        revert("Set NETWORK env (e.g. mainnet|sepolia)");
    }

    /// @dev Reads `<network>.<field>` from the JSON and reverts if it is unset/zero.
    function _readAddress(string memory json, string memory network, string memory field)
        internal
        pure
        returns (address)
    {
        bytes memory raw = vm.parseJson(json, string.concat(".", network, ".", field));
        address value = abi.decode(raw, (address));
        if (value == address(0)) revert AddressNotConfigured(field);
        return value;
    }
}
