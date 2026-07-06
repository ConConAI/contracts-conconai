// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Presale} from "../../src/Presale.sol";
import {PresaleHandler} from "./PresaleHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Presale invariant tests
/// @notice Verifies core accounting invariants hold under randomized sequences of buys and claims.
/// @dev Invariants:
///      - sum(purchased) + totalClaimed == totalSold   [base + stacking bonuses]
///      - CON balance >= (totalSold - totalClaimed)   [contract always covers outstanding claims]
///      - phase.sold <= cap for every phase
///      - totalSold <= PRESALE_CAP   [base + bonuses never exceed the global cap]
contract PresaleInvariantTest is Test {
    Presale internal presale;
    PresaleHandler internal handler;
    MockERC20 internal con;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockAggregator internal feed;

    address internal admin = makeAddr("admin");
    uint256 internal constant FUND = 50_000_000 * 1e18;

    function setUp() public {
        con = new MockERC20("ConCon", "CON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        feed = new MockAggregator(8, 2000e8);

        presale = new Presale(
            IERC20(address(con)),
            IERC20(address(usdc)),
            IERC20(address(usdt)),
            feed,
            admin,
            block.timestamp + 3651 days,
            block.timestamp + 3654 days
        );
        con.mint(address(presale), FUND);

        vm.startPrank(admin);
        presale.startPhase(0, 3650 days);
        presale.enableClaim();
        vm.stopPrank();

        handler = new PresaleHandler(presale, con, usdc, feed);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PresaleHandler.buyStable.selector;
        selectors[1] = PresaleHandler.buyETH.selector;
        selectors[2] = PresaleHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SumPurchasedPlusClaimedEqualsTotalSold() public view {
        assertEq(handler.sumPurchased() + presale.totalClaimed(), presale.totalSold());
    }

    function invariant_BalanceCoversOutstanding() public view {
        assertGe(con.balanceOf(address(presale)), presale.totalSold() - presale.totalClaimed());
    }

    function invariant_PhaseSoldWithinCap() public view {
        for (uint8 i = 0; i < presale.NUM_PHASES(); ++i) {
            (, uint256 cap, uint256 sold,,) = presale.phases(i);
            assertLe(sold, cap);
        }
    }

    function invariant_TotalSoldWithinPresaleCap() public view {
        assertLe(presale.totalSold(), presale.PRESALE_CAP());
    }
}
