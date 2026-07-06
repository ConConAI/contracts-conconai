// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title ConToken ($CON)
/// @author ConConAI
/// @notice Fixed-supply ERC20 utility token for the ConCon ecosystem. The entire supply of
///         100,000,000 CON (18 decimals) is minted once to the treasury at deployment.
/// @dev    Trust-minimised by design:
///         - No `mint` function exists anywhere, so supply is permanently fixed after deploy.
///         - There is no owner/admin and therefore NO special powers over balances.
///         - No pause, no blacklist, and no transfer hooks that can block transfers.
///         - `ERC20Permit` enables gasless (EIP-2612) approvals.
///         - `ERC20Burnable` lets holders voluntarily burn their own tokens (supply can only
///           ever decrease, never increase).
///         A professional security audit is required before any mainnet use.
contract ConToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Human-readable token name, exposed as a constant for easy off-chain confirmation.
    string public constant TOKEN_NAME = "ConCon";

    /// @notice Token ticker symbol, exposed as a constant for easy off-chain confirmation.
    string public constant TOKEN_SYMBOL = "CON";

    /// @notice The full fixed supply minted at genesis: 100,000,000 CON with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18;

    /// @notice Thrown when the treasury address supplied to the constructor is the zero address.
    error ZeroTreasury();

    /// @notice Deploys the token and mints the entire fixed supply to `treasury`.
    /// @dev Reverts with {ZeroTreasury} if `treasury` is the zero address. No further minting is
    ///      ever possible because no mint entry point is exposed.
    /// @param treasury The recipient of the full 100,000,000 CON supply.
    constructor(address treasury) ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        if (treasury == address(0)) {
            revert ZeroTreasury();
        }
        _mint(treasury, INITIAL_SUPPLY);
    }
}
