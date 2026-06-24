// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDT (TESTNET ONLY)
/// @author ConConAI
/// @notice A 6-decimal, freely mintable ERC20 standing in for USDT on Sepolia.
/// @dev    TESTNET ONLY. This contract has an unrestricted public {mint} and MUST NEVER be deployed
///         to mainnet or used in production. It exists purely to exercise the presale end-to-end on
///         a testnet without real USDT.
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock Tether USD", "USDT") {}

    /// @notice USDT uses 6 decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint test tokens to any address. Unrestricted on purpose (TESTNET ONLY).
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount to mint (6 decimals).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
