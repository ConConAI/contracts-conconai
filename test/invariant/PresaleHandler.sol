// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Presale} from "../../src/Presale.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PresaleHandler
/// @notice Drives randomized buys and claims across a fixed set of actors for invariant testing.
/// @dev Each action guards its preconditions so calls succeed and meaningfully exercise state.
contract PresaleHandler is Test {
    Presale internal immutable PRESALE;
    MockERC20 internal immutable CON;
    MockERC20 internal immutable USDC;
    MockAggregator internal immutable FEED;

    uint256 public constant NUM_ACTORS = 5;
    address[] public actors;

    uint256 internal constant PRICE_P0 = 5000;

    constructor(Presale presale_, MockERC20 con_, MockERC20 usdc_, MockAggregator feed_) {
        PRESALE = presale_;
        CON = con_;
        USDC = usdc_;
        FEED = feed_;
        for (uint256 i = 0; i < NUM_ACTORS; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("presale-actor", i))))));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buyStable(uint256 actorSeed, uint256 amount) external {
        uint256 remaining = PRESALE.remainingInActivePhase();
        if (remaining == 0) return;

        amount = bound(amount, 1, 120_000 * 1e6);
        uint256 conAmount = (amount * 1e18) / PRICE_P0;
        if (conAmount == 0) return;

        address actor = _actor(actorSeed);
        USDC.mint(actor, amount);
        vm.startPrank(actor);
        USDC.approve(address(PRESALE), amount);
        PRESALE.buyWithStable(IERC20(address(USDC)), amount);
        vm.stopPrank();
    }

    function buyETH(uint256 actorSeed, uint256 value) external {
        uint256 remaining = PRESALE.remainingInActivePhase();
        if (remaining == 0) return;

        value = bound(value, 1, 50 ether);
        uint256 usdE6 = (value * 2000e8) / 1e20;
        uint256 conAmount = (usdE6 * 1e18) / PRICE_P0;
        if (conAmount == 0) return;

        address actor = _actor(actorSeed);
        vm.deal(actor, value);
        vm.prank(actor);
        PRESALE.buyWithETH{value: value}();
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (PRESALE.purchased(actor) == 0) return;
        vm.prank(actor);
        PRESALE.claim();
    }

    /// @notice Sum of unclaimed booked allocations across all actors.
    function sumPurchased() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; ++i) {
            total += PRESALE.purchased(actors[i]);
        }
    }
}
