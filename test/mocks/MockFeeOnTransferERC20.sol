// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockFeeOnTransferERC20
/// @notice A 6-decimal ERC20 that skims a fee on every transfer, so the recipient receives less
///         than the sent amount. Used to verify the presale rejects fee-on-transfer stables.
contract MockFeeOnTransferERC20 is ERC20 {
    /// @notice Fee taken on each transfer, in basis points (100 == 1%).
    uint256 public constant FEE_BPS = 100;

    address internal constant FEE_SINK = address(0xFEE);

    constructor() ERC20("Fee USD Coin", "fUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Apply the fee only on real transfers (not mint/burn).
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, FEE_SINK, fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
