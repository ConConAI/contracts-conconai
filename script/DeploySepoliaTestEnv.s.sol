// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConToken} from "../src/ConToken.sol";
import {Presale} from "../src/Presale.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";

/// @title DeploySepoliaTestEnv (TESTNET ONLY)
/// @author ConConAI
/// @notice Deploys a self-contained presale test environment to Sepolia: a fresh test {ConToken},
///         {MockUSDC} + {MockUSDT} + {MockAggregatorV3}, and a {Presale} bound to them, then funds the
///         presale with 50,000,000 test CON so claims can be paid out.
/// @dev    TESTNET ONLY - this reverts on Ethereum mainnet. It deploys a TEST copy of the token and
///         freely-mintable mocks; the real mainnet $CON is never touched.
///
///         Signing comes from the USER's own wallet at runtime (e.g. --account or --ledger); there are
///         NO hardcoded keys. The treasury/admin is read from `deployments/addresses.json`
///         (`sepolia.admin`). Because the test CON is minted to that treasury and then transferred into
///         the presale within the same broadcast, you MUST run this with the `sepolia.admin` wallet.
contract DeploySepoliaTestEnv is Script {
    /// @notice Test CON moved into the presale to back claims (50,000,000 with 18 decimals).
    uint256 internal constant PRESALE_FUNDING = 50_000_000 * 1e18;

    /// @notice Seed ETH/USD price for the mock oracle: $3000 with 8 decimals.
    int256 internal constant SEED_ETH_USD = 3000e8;

    /// @notice Sepolia chain id.
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    error MainnetForbidden();
    error AdminNotConfigured();

    /// @notice Deploys and wires the full Sepolia test environment in a single broadcast.
    /// @return token The deployed test {ConToken}.
    /// @return usdc The deployed {MockUSDC}.
    /// @return usdt The deployed {MockUSDT}.
    /// @return feed The deployed {MockAggregatorV3}.
    /// @return presale The deployed {Presale}, funded with {PRESALE_FUNDING} test CON.
    function run()
        external
        returns (ConToken token, MockUSDC usdc, MockUSDT usdt, MockAggregatorV3 feed, Presale presale)
    {
        if (block.chainid == 1) revert MainnetForbidden();

        string memory json = vm.readFile("deployments/addresses.json");
        bytes memory raw = vm.parseJson(json, ".sepolia.admin");
        address admin = abi.decode(raw, (address));
        if (admin == address(0)) revert AdminNotConfigured();

        console2.log("Deploying Sepolia TEST environment (TESTNET ONLY)");
        console2.log("  chainId:", block.chainid);
        console2.log("  treasury/admin:", admin);

        vm.startBroadcast();

        // Fresh TEST copy of the token (mints 100,000,000 test CON to the admin/treasury).
        token = new ConToken(admin);

        // Freely-mintable 6-decimal stablecoin mocks + a settable 8-decimal ETH/USD oracle.
        usdc = new MockUSDC();
        usdt = new MockUSDT();
        feed = new MockAggregatorV3(SEED_ETH_USD);

        // Presale bound to the test token + mocks; owner/treasury is the admin.
        presale = new Presale(IERC20(address(token)), IERC20(address(usdc)), IERC20(address(usdt)), feed, admin);

        // Fund the presale so claims can be paid (requires the broadcaster to be the admin/treasury).
        // forge-lint: disable-next-line(erc20-unchecked-transfer) - ConToken returns true or reverts.
        token.transfer(address(presale), PRESALE_FUNDING);

        vm.stopBroadcast();

        _report(token, usdc, usdt, feed, presale, admin);
    }

    /// @dev Prints every deployed address plus copy-paste snippets for addresses.json and .env.local.
    function _report(
        ConToken token,
        MockUSDC usdc,
        MockUSDT usdt,
        MockAggregatorV3 feed,
        Presale presale,
        address admin
    ) internal view {
        console2.log("");
        console2.log("=== Deployed (Sepolia, TESTNET ONLY) ===");
        console2.log("  test ConToken:", address(token));
        console2.log("  MockUSDC:", address(usdc));
        console2.log("  MockUSDT:", address(usdt));
        console2.log("  MockAggregatorV3 (ETH/USD):", address(feed));
        console2.log("  Presale:", address(presale));
        console2.log("  Presale funded with 50,000,000 test CON");

        console2.log("");
        console2.log("--- Paste into deployments/addresses.json (sepolia) ---");
        console2.log("  \"sepolia\": {");
        console2.log("    \"chainId\": 11155111,");
        console2.log(string.concat("    \"token\": \"", vm.toString(address(token)), "\","));
        console2.log(string.concat("    \"admin\": \"", vm.toString(admin), "\","));
        console2.log(string.concat("    \"presale\": \"", vm.toString(address(presale)), "\","));
        console2.log(string.concat("    \"usdc\": \"", vm.toString(address(usdc)), "\","));
        console2.log(string.concat("    \"usdt\": \"", vm.toString(address(usdt)), "\","));
        console2.log(string.concat("    \"ethUsdFeed\": \"", vm.toString(address(feed)), "\""));
        console2.log("  }");

        console2.log("");
        console2.log("--- Paste into the website .env.local ---");
        console2.log("NEXT_PUBLIC_ICO_CHAIN=sepolia");
        console2.log("NEXT_PUBLIC_ICO_LIVE=true");
        console2.log(string.concat("NEXT_PUBLIC_PRESALE_ADDRESS_SEPOLIA=", vm.toString(address(presale))));
        console2.log(string.concat("NEXT_PUBLIC_CON_ADDRESS_SEPOLIA=", vm.toString(address(token))));
        console2.log(string.concat("NEXT_PUBLIC_USDC_ADDRESS_SEPOLIA=", vm.toString(address(usdc))));
        console2.log(string.concat("NEXT_PUBLIC_USDT_ADDRESS_SEPOLIA=", vm.toString(address(usdt))));
    }
}
