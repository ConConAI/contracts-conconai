// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Presale} from "../src/Presale.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Presale test suite
/// @notice Unit + fuzz coverage for the phased $CON presale: booking math, cap clamping, oracle
///         guards, lifecycle gating, claiming, admin powers and the Ownable2Step flow.
contract PresaleTest is Test {
    Presale internal presale;
    MockERC20 internal con;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockAggregator internal feed;

    address internal admin = makeAddr("admin"); // owner + treasury
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant CAP = 10_000_000 * 1e18;
    uint256 internal constant FUND = 50_000_000 * 1e18;
    int256 internal constant ETH_PRICE = 2000e8; // $2000 / ETH, 8 decimals
    uint64 internal constant LONG = 365 days;

    function setUp() public {
        con = new MockERC20("ConCon", "CON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        feed = new MockAggregator(8, ETH_PRICE);

        presale = new Presale(IERC20(address(con)), IERC20(address(usdc)), IERC20(address(usdt)), feed, admin);

        // Fund the presale so claims can be paid out (treasury action in production).
        con.mint(address(presale), FUND);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _startPhase(uint8 i, uint64 duration) internal {
        vm.prank(admin);
        presale.startPhase(i, duration);
    }

    function _buyStable(address who, MockERC20 token, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(presale), amount);
        presale.buyWithStable(IERC20(address(token)), amount);
        vm.stopPrank();
    }

    function _phaseSold(uint8 i) internal view returns (uint256 sold) {
        (,, sold,,) = presale.phases(i);
    }

    function _phaseEndsAt(uint8 i) internal view returns (uint64 endsAt) {
        (,,,, endsAt) = presale.phases(i);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsConfig() public view {
        assertEq(address(presale.CON_TOKEN()), address(con));
        assertEq(address(presale.USDC()), address(usdc));
        assertEq(address(presale.USDT()), address(usdt));
        assertEq(address(presale.ETH_USD_FEED()), address(feed));
        assertEq(presale.TREASURY(), admin);
        assertEq(presale.owner(), admin);

        (uint256 p0,,,,) = presale.phases(0);
        (uint256 p4, uint256 cap4,,,) = presale.phases(4);
        assertEq(p0, 5000);
        assertEq(p4, 9000);
        assertEq(cap4, CAP);
    }

    function test_ConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(Presale.ZeroAddress.selector);
        new Presale(IERC20(address(0)), IERC20(address(usdc)), IERC20(address(usdt)), feed, admin);

        vm.expectRevert(Presale.ZeroAddress.selector);
        new Presale(IERC20(address(con)), IERC20(address(0)), IERC20(address(usdt)), feed, admin);

        vm.expectRevert(Presale.ZeroAddress.selector);
        new Presale(IERC20(address(con)), IERC20(address(usdc)), IERC20(address(0)), feed, admin);

        vm.expectRevert(Presale.ZeroAddress.selector);
        new Presale(
            IERC20(address(con)), IERC20(address(usdc)), IERC20(address(usdt)), IAggregatorV3(address(0)), admin
        );

        // A zero treasury is rejected by Ownable's own guard (it is the initial owner), which runs
        // before the body. Still a zero-address revert, just a different selector.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Presale(IERC20(address(con)), IERC20(address(usdc)), IERC20(address(usdt)), feed, address(0));
    }

    function test_ConstructorRevertsOnWrongFeedDecimals() public {
        MockAggregator badFeed = new MockAggregator(18, ETH_PRICE);
        vm.expectRevert(Presale.InvalidFeedDecimals.selector);
        new Presale(IERC20(address(con)), IERC20(address(usdc)), IERC20(address(usdt)), badFeed, admin);
    }

    /*//////////////////////////////////////////////////////////////
                            BUY WITH STABLE
    //////////////////////////////////////////////////////////////*/

    function test_BuyWithUSDC() public {
        _startPhase(0, LONG);
        uint256 amount = 5_000_000; // 5 USDC (6 decimals) -> $5
        _buyStable(alice, usdc, amount);

        uint256 expected = (amount * 1e18) / 5000; // 1000 CON
        assertEq(expected, 1000 * 1e18);
        assertEq(presale.purchased(alice), expected);
        assertEq(_phaseSold(0), expected);
        assertEq(presale.totalSold(), expected);
        assertEq(usdc.balanceOf(address(presale)), amount);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_BuyWithUSDT() public {
        _startPhase(0, LONG);
        uint256 amount = 9_000_000; // 9 USDT -> $9
        _buyStable(bob, usdt, amount);

        uint256 expected = (amount * 1e18) / 5000;
        assertEq(presale.purchased(bob), expected);
        assertEq(usdt.balanceOf(address(presale)), amount);
    }

    function test_BuyRevertsOnUnsupportedStable() public {
        _startPhase(0, LONG);
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        dai.mint(alice, 1e18);
        vm.startPrank(alice);
        dai.approve(address(presale), 1e18);
        vm.expectRevert(Presale.UnsupportedStable.selector);
        presale.buyWithStable(IERC20(address(dai)), 1e18);
        vm.stopPrank();
    }

    function test_BuyRevertsOnZeroAmount() public {
        _startPhase(0, LONG);
        vm.prank(alice);
        vm.expectRevert(Presale.ZeroPayment.selector);
        presale.buyWithStable(IERC20(address(usdc)), 0);
    }

    function test_MultiPhasePricing() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000); // $5 @ $0.005 -> 1000 CON
        assertEq(presale.purchased(alice), 1000 * 1e18);

        _startPhase(1, LONG); // price $0.006
        _buyStable(alice, usdc, 6_000_000); // $6 @ $0.006 -> 1000 CON
        assertEq(presale.purchased(alice), 2000 * 1e18);
        assertEq(presale.currentPhase(), 1);
        assertEq(_phaseSold(1), 1000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            CAP CLAMP (STABLE)
    //////////////////////////////////////////////////////////////*/

    function test_StableCapClampChargesExactRequired() public {
        _startPhase(0, LONG);
        // 60,000 USDC -> 12,000,000 CON desired, but cap is 10,000,000 CON.
        uint256 amount = 60_000 * 1e6;
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(presale), amount);
        presale.buyWithStable(IERC20(address(usdc)), amount);
        vm.stopPrank();

        // Base booked exactly the remaining phase cap (10M CON); the phase cap counts base only.
        assertEq(_phaseSold(0), CAP);
        // Charged only the exact cost: 10,000,000 * 5000 / 1e18 (in 6 decimals) = 50,000 USDC.
        uint256 required = (CAP * 5000) / 1e18;
        assertEq(required, 50_000 * 1e6);
        assertEq(usdc.balanceOf(address(presale)), required);
        // Buyer keeps the unspent 10,000 USDC.
        assertEq(usdc.balanceOf(alice), amount - required);

        // The charged $50k crosses all three stacking bonus tiers (+600k CON), booked on top of base.
        assertEq(presale.contributedUsd(alice), required);
        assertEq(presale.bonusTiersAwarded(alice), 3);
        assertEq(presale.purchased(alice), CAP + 600_000 * 1e18);
    }

    function test_BuyRevertsWhenPhaseSoldOut() public {
        _startPhase(0, LONG);
        uint256 amount = 60_000 * 1e6;
        _buyStable(alice, usdc, amount); // fills the cap

        assertEq(_phaseSold(0), CAP);

        usdc.mint(bob, 5_000_000);
        vm.startPrank(bob);
        usdc.approve(address(presale), 5_000_000);
        vm.expectRevert(Presale.PhaseSoldOut.selector);
        presale.buyWithStable(IERC20(address(usdc)), 5_000_000);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              BUY WITH ETH
    //////////////////////////////////////////////////////////////*/

    function test_BuyWithETHBooksCorrectAmount() public {
        _startPhase(0, LONG);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        presale.buyWithETH{value: 1 ether}();

        // $2000 worth at $0.005 -> 400,000 CON. Exact, no refund.
        assertEq(presale.purchased(alice), 400_000 * 1e18);
        assertEq(address(presale).balance, 1 ether);
        assertEq(alice.balance, 0);
    }

    function test_BuyWithETHRefundsExcessOnClamp() public {
        _startPhase(0, LONG);
        // Pre-fill the cap down to 1000 CON remaining via a stable buy.
        uint256 fillCon = CAP - 1000 * 1e18;
        uint256 fillUsdc = (fillCon * 5000) / 1e18;
        _buyStable(bob, usdc, fillUsdc);
        assertEq(presale.remainingInActivePhase(), 1000 * 1e18);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        presale.buyWithETH{value: 1 ether}();

        // Booked only the remaining 1000 CON.
        assertEq(presale.purchased(alice), 1000 * 1e18);

        // Required ETH for 1000 CON @ $0.005 = $5 = 5/2000 ETH = 0.0025 ether.
        uint256 requiredEth = (((1000 * 1e18 * 5000) / 1e18) * 1e20) / uint256(ETH_PRICE);
        assertEq(requiredEth, 0.0025 ether);
        assertEq(address(presale).balance, requiredEth);
        assertEq(alice.balance, 1 ether - requiredEth);
    }

    function test_BuyWithETHRevertsOnZeroValue() public {
        _startPhase(0, LONG);
        vm.prank(alice);
        vm.expectRevert(Presale.ZeroPayment.selector);
        presale.buyWithETH{value: 0}();
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_ETHBuyRevertsOnZeroPrice() public {
        _startPhase(0, LONG);
        feed.setAnswer(0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Presale.OracleInvalidPrice.selector);
        presale.buyWithETH{value: 1 ether}();
    }

    function test_ETHBuyRevertsOnNegativePrice() public {
        _startPhase(0, LONG);
        feed.setAnswer(-1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Presale.OracleInvalidPrice.selector);
        presale.buyWithETH{value: 1 ether}();
    }

    function test_ETHBuyRevertsOnStalePrice() public {
        _startPhase(0, LONG);
        vm.warp(block.timestamp + 2 hours); // feed.updatedAt remains old
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Presale.OracleStale.selector);
        presale.buyWithETH{value: 1 ether}();
    }

    function test_ETHBuyRevertsOnIncompleteRound() public {
        _startPhase(0, LONG);
        feed.setRound(5, 4); // answeredInRound < roundId
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Presale.OracleRoundIncomplete.selector);
        presale.buyWithETH{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
                          LIFECYCLE GATING
    //////////////////////////////////////////////////////////////*/

    function test_BuyRevertsWhenNotStarted() public {
        vm.prank(alice);
        vm.expectRevert(Presale.PhaseNotStarted.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1e6);
    }

    function test_BuyRevertsAfterEndsAt() public {
        _startPhase(0, 100);
        vm.warp(block.timestamp + 101);
        vm.prank(alice);
        vm.expectRevert(Presale.PhaseExpired.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1e6);
    }

    function test_BuyRevertsWhenPresaleEnded() public {
        _startPhase(0, LONG);
        vm.prank(admin);
        presale.endPresale();
        vm.prank(alice);
        vm.expectRevert(Presale.PresaleIsEnded.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1e6);
    }

    function test_BuyRevertsWhenPaused() public {
        _startPhase(0, LONG);
        vm.prank(admin);
        presale.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRevertsBeforeEnabled() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000);
        vm.prank(alice);
        vm.expectRevert(Presale.ClaimNotOpen.selector);
        presale.claim();
    }

    function test_ClaimSucceedsAfterEnabled() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000);
        uint256 amt = presale.purchased(alice);

        vm.prank(admin);
        presale.enableClaim();

        vm.prank(alice);
        presale.claim();

        assertEq(con.balanceOf(alice), amt);
        assertEq(presale.purchased(alice), 0);
        assertEq(presale.claimed(alice), amt);
        assertEq(presale.totalClaimed(), amt);
        assertEq(con.balanceOf(address(presale)), FUND - amt);
    }

    function test_DoubleClaimReverts() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000);
        vm.prank(admin);
        presale.enableClaim();

        uint256 amt = presale.purchased(alice);
        vm.prank(alice);
        presale.claim();

        // Claimed tracker reflects the claim and the allocation is zeroed.
        assertEq(presale.claimed(alice), amt);
        assertEq(presale.purchased(alice), 0);

        vm.prank(alice);
        vm.expectRevert(Presale.NothingToClaim.selector);
        presale.claim();

        // A reverted double-claim does not change the tracker.
        assertEq(presale.claimed(alice), amt);
    }

    function test_ClaimRevertsForZeroAllocation() public {
        _startPhase(0, LONG);
        vm.prank(admin);
        presale.enableClaim();
        vm.prank(bob);
        vm.expectRevert(Presale.NothingToClaim.selector);
        presale.claim();
    }

    function test_ClaimWorksWhilePaused() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000);
        vm.startPrank(admin);
        presale.enableClaim();
        presale.pause();
        vm.stopPrank();

        vm.prank(alice);
        presale.claim();
        assertEq(con.balanceOf(alice), 1000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawStableToTreasury() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000);

        vm.prank(admin);
        presale.withdraw(address(usdc));
        assertEq(usdc.balanceOf(admin), 5_000_000);
        assertEq(usdc.balanceOf(address(presale)), 0);
    }

    function test_WithdrawETHToTreasury() public {
        _startPhase(0, LONG);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        presale.buyWithETH{value: 1 ether}();

        uint256 before = admin.balance;
        vm.prank(admin);
        presale.withdraw(address(0));
        assertEq(admin.balance, before + 1 ether);
        assertEq(address(presale).balance, 0);
    }

    function test_WithdrawRevertsForConToken() public {
        vm.prank(admin);
        vm.expectRevert(Presale.CannotWithdrawConToken.selector);
        presale.withdraw(address(con));
    }

    function test_WithdrawRevertsWhenNothing() public {
        vm.prank(admin);
        vm.expectRevert(Presale.NothingToWithdraw.selector);
        presale.withdraw(address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                             SWEEP UNSOLD
    //////////////////////////////////////////////////////////////*/

    function test_SweepUnsoldLeavesClaimsCovered() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000); // books 1000 CON
        uint256 outstanding = presale.totalSold();

        // Unsold CON can only be swept once the presale has ended.
        vm.prank(admin);
        presale.endPresale();

        uint256 treasuryBefore = con.balanceOf(admin);
        vm.prank(admin);
        presale.sweepUnsold();

        // Excess swept; exactly the outstanding allocation remains in the contract.
        assertEq(con.balanceOf(admin), treasuryBefore + (FUND - outstanding));
        assertEq(con.balanceOf(address(presale)), outstanding);

        // Claim still fully covered.
        vm.prank(admin);
        presale.enableClaim();
        vm.prank(alice);
        presale.claim();
        assertEq(con.balanceOf(alice), outstanding);
        assertEq(con.balanceOf(address(presale)), 0);
    }

    function test_SweepRevertsWhenNothingToSweep() public {
        // Deploy a fresh presale funded with exactly the outstanding amount (none excess).
        Presale p = new Presale(IERC20(address(con)), IERC20(address(usdc)), IERC20(address(usdt)), feed, admin);
        vm.prank(admin);
        p.startPhase(0, LONG);
        usdc.mint(alice, 5_000_000);
        vm.startPrank(alice);
        usdc.approve(address(p), 5_000_000);
        p.buyWithStable(IERC20(address(usdc)), 5_000_000);
        vm.stopPrank();
        con.mint(address(p), p.totalSold()); // fund exactly outstanding

        vm.startPrank(admin);
        p.endPresale();
        vm.expectRevert(Presale.NothingToSweep.selector);
        p.sweepUnsold();
        vm.stopPrank();
    }

    function test_SweepRevertsBeforePresaleEnded() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 5_000_000); // books 1000 CON, leaving plenty of excess CON

        // Even with excess CON present, sweeping is blocked until the presale ends.
        vm.prank(admin);
        vm.expectRevert(Presale.PresaleNotEnded.selector);
        presale.sweepUnsold();
    }

    function test_RemainingInActivePhaseClampedToGlobalCap() public {
        uint256[4] memory prices = [uint256(5000), 6000, 7000, 8000];
        for (uint8 i = 0; i < 4; ++i) {
            _startPhase(i, LONG);
            address whale = makeAddr(string(abi.encodePacked("capwhale", i)));
            uint256 amount = 10_000_000 * prices[i]; // fills the 10M base cap at this phase price
            usdc.mint(whale, amount);
            vm.startPrank(whale);
            usdc.approve(address(presale), amount);
            presale.buyWithStable(IERC20(address(usdc)), amount);
            vm.stopPrank();
        }

        // 4 phases filled: 40M base + 4 x 600k bonus = 42.4M sold; global remaining = 7.6M.
        _startPhase(4, LONG);
        uint256 globalRemaining = PRESALE_CAP - presale.totalSold();
        assertEq(globalRemaining, 7_600_000 * 1e18);

        // Phase 4 still has the full 10M base room, but the view is clamped to the global remaining.
        (, uint256 cap4, uint256 sold4,,) = presale.phases(4);
        assertEq(cap4 - sold4, CAP);
        assertEq(presale.remainingInActivePhase(), globalRemaining);
        assertLt(presale.remainingInActivePhase(), cap4 - sold4);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN / PHASE CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_StartPhaseAllowsFreeSwitching() public {
        // Owner can jump straight to any phase (0 -> 2), no sequential restriction.
        _startPhase(2, LONG);
        assertEq(presale.currentPhase(), 2);

        // Buying in the jumped-to phase uses that phase's price ($0.007 -> 1000 CON for $7).
        _buyStable(alice, usdc, 7_000_000);
        assertEq(presale.purchased(alice), 1000 * 1e18);

        // Can jump forward again (2 -> 4).
        _startPhase(4, LONG);
        assertEq(presale.currentPhase(), 4);

        // Can go backwards (4 -> 1).
        _startPhase(1, LONG);
        assertEq(presale.currentPhase(), 1);

        // Restarting the active phase is allowed too.
        _startPhase(1, LONG);
        assertEq(presale.currentPhase(), 1);
    }

    function test_StartPhaseRevertsOnInvalidIndex() public {
        _startPhase(0, LONG);
        _startPhase(1, LONG);
        _startPhase(2, LONG);
        _startPhase(3, LONG);
        _startPhase(4, LONG);
        vm.prank(admin);
        vm.expectRevert(Presale.InvalidPhaseIndex.selector);
        presale.startPhase(5, LONG);
    }

    function test_StartPhaseRevertsOnZeroDuration() public {
        vm.prank(admin);
        vm.expectRevert(Presale.ZeroDuration.selector);
        presale.startPhase(0, 0);
    }

    function test_SetTimerAndExtendTimer() public {
        _startPhase(0, 100);
        uint64 base = _phaseEndsAt(0);

        vm.prank(admin);
        presale.setTimer(base + 1000);
        assertEq(_phaseEndsAt(0), base + 1000);

        vm.prank(admin);
        presale.extendTimer(500);
        assertEq(_phaseEndsAt(0), base + 1500);
    }

    function test_SetTimerRevertsWhenNoActivePhase() public {
        vm.prank(admin);
        vm.expectRevert(Presale.PhaseNotStarted.selector);
        presale.setTimer(uint64(block.timestamp + 1000));
    }

    function test_EndPhaseStopsSales() public {
        _startPhase(0, LONG);
        vm.prank(admin);
        presale.endPhase();
        assertEq(_phaseEndsAt(0), uint64(block.timestamp));

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(Presale.PhaseExpired.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                            ONE-WAY FLAGS
    //////////////////////////////////////////////////////////////*/

    function test_EndPresaleIsOneWay() public {
        vm.startPrank(admin);
        presale.endPresale();
        assertTrue(presale.presaleEnded());
        vm.expectRevert(Presale.PresaleIsEnded.selector);
        presale.endPresale();
        vm.stopPrank();
    }

    function test_EnableClaimIsOneWay() public {
        vm.startPrank(admin);
        presale.enableClaim();
        assertTrue(presale.claimOpen());
        vm.expectRevert(Presale.ClaimAlreadyOpen.selector);
        presale.enableClaim();
        vm.stopPrank();
    }

    function test_EnableClaimIndependentOfEndPresale() public {
        vm.prank(admin);
        presale.enableClaim();
        assertTrue(presale.claimOpen());
        assertFalse(presale.presaleEnded());
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_NonOwnerRevertsOnAdminFunctions() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);
        vm.startPrank(attacker);

        vm.expectRevert(err);
        presale.startPhase(0, LONG);
        vm.expectRevert(err);
        presale.setTimer(1);
        vm.expectRevert(err);
        presale.extendTimer(1);
        vm.expectRevert(err);
        presale.endPhase();
        vm.expectRevert(err);
        presale.endPresale();
        vm.expectRevert(err);
        presale.enableClaim();
        vm.expectRevert(err);
        presale.pause();
        vm.expectRevert(err);
        presale.unpause();
        vm.expectRevert(err);
        presale.withdraw(address(usdc));
        vm.expectRevert(err);
        presale.sweepUnsold();

        vm.stopPrank();
    }

    function test_Ownable2StepTransferFlow() public {
        vm.prank(admin);
        presale.transferOwnership(bob);
        // Ownership not transferred until accepted.
        assertEq(presale.owner(), admin);
        assertEq(presale.pendingOwner(), bob);

        // Non-pending cannot accept.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        presale.acceptOwnership();

        vm.prank(bob);
        presale.acceptOwnership();
        assertEq(presale.owner(), bob);
        assertEq(presale.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                             STACKING BONUS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRESALE_CAP = 50_000_000 * 1e18;
    uint256 internal constant TIER1_CON = 50_000 * 1e18;
    uint256 internal constant TIER2_CON = 150_000 * 1e18;
    uint256 internal constant TIER3_CON = 400_000 * 1e18;

    function test_BonusSingleBuy10kAwardsTier1() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 10_000 * 1e6); // $10k @ $0.005 -> 2,000,000 base

        uint256 base = (10_000 * 1e6 * 1e18) / 5000;
        assertEq(base, 2_000_000 * 1e18);
        assertEq(presale.purchased(alice), base + TIER1_CON);
        assertEq(presale.bonusTiersAwarded(alice), 1);
        assertEq(presale.contributedUsd(alice), 10_000 * 1e6);
        // Bonus is booked into totals but NOT into the phase cap.
        assertEq(_phaseSold(0), base);
        assertEq(presale.totalSold(), base + TIER1_CON);
    }

    function test_BonusSingleBuy25kStacksTwoTiers() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 25_000 * 1e6);

        uint256 base = (25_000 * 1e6 * 1e18) / 5000; // 5,000,000
        assertEq(presale.purchased(alice), base + TIER1_CON + TIER2_CON); // +200k
        assertEq(presale.bonusTiersAwarded(alice), 2);
    }

    function test_BonusSingleBuy50kStacksAllTiers() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 50_000 * 1e6);

        uint256 base = (50_000 * 1e6 * 1e18) / 5000; // 10,000,000 == phase cap
        assertEq(base, CAP);
        assertEq(presale.purchased(alice), base + 600_000 * 1e18); // +600k
        assertEq(presale.bonusTiersAwarded(alice), 3);
        assertEq(_phaseSold(0), CAP);
        assertEq(presale.totalSold(), CAP + 600_000 * 1e18);
    }

    function test_BonusIsClaimable() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 10_000 * 1e6);
        uint256 owed = presale.purchased(alice);

        vm.prank(admin);
        presale.enableClaim();
        vm.prank(alice);
        presale.claim();

        assertEq(con.balanceOf(alice), owed);
        assertEq(con.balanceOf(alice), 2_000_000 * 1e18 + TIER1_CON);
    }

    function test_BonusStepwiseAwardsEachTierOnce() public {
        _startPhase(0, LONG);

        // $5k: below tier 1 -> no bonus.
        _buyStable(alice, usdc, 5000 * 1e6);
        assertEq(presale.bonusTiersAwarded(alice), 0);
        assertEq(presale.purchased(alice), 1_000_000 * 1e18);

        // +$5k (=$10k): crosses tier 1 -> +50k.
        _buyStable(alice, usdc, 5000 * 1e6);
        assertEq(presale.bonusTiersAwarded(alice), 1);
        assertEq(presale.purchased(alice), 2_000_000 * 1e18 + TIER1_CON);

        // +$15k (=$25k): crosses tier 2 -> +150k.
        _buyStable(alice, usdc, 15_000 * 1e6);
        assertEq(presale.bonusTiersAwarded(alice), 2);
        assertEq(presale.purchased(alice), 5_000_000 * 1e18 + TIER1_CON + TIER2_CON);

        // +$25k (=$50k): crosses tier 3 -> +400k. Base now exactly the 10M phase cap.
        _buyStable(alice, usdc, 25_000 * 1e6);
        assertEq(presale.bonusTiersAwarded(alice), 3);
        assertEq(presale.purchased(alice), CAP + 600_000 * 1e18);
        assertEq(_phaseSold(0), CAP);
    }

    function test_BonusNotReAwardedOnceAtTopTier() public {
        _startPhase(0, LONG);
        _buyStable(alice, usdc, 50_000 * 1e6); // tier 3, fills phase 0 base cap
        uint256 purchasedAfterP0 = presale.purchased(alice);
        assertEq(presale.bonusTiersAwarded(alice), 3);

        // Move to phase 1 and contribute more: no further bonus, tier stays 3.
        _startPhase(1, LONG);
        _buyStable(alice, usdc, 10_000 * 1e6); // $10k @ $0.006
        uint256 amtP1 = 10_000 * 1e6;
        uint256 baseP1 = (amtP1 * 1e18) / 6000;

        assertEq(presale.bonusTiersAwarded(alice), 3);
        assertEq(presale.purchased(alice), purchasedAfterP0 + baseP1);
        assertEq(presale.contributedUsd(alice), 60_000 * 1e6);
    }

    function test_BonusViaETHDrivesTiers() public {
        _startPhase(0, LONG);
        // $2000/ETH: 5 ETH == $10,000 -> crosses tier 1.
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        presale.buyWithETH{value: 5 ether}();

        uint256 base = (10_000 * 1e6 * 1e18) / 5000; // 2,000,000
        assertEq(presale.purchased(alice), base + TIER1_CON);
        assertEq(presale.bonusTiersAwarded(alice), 1);
        assertEq(presale.contributedUsd(alice), 10_000 * 1e6);
    }

    function test_BonusAwardedEventEmitted() public {
        _startPhase(0, LONG);
        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(presale), 10_000 * 1e6);
        vm.expectEmit(true, false, false, true, address(presale));
        emit Presale.BonusAwarded(alice, TIER1_CON, 1);
        presale.buyWithStable(IERC20(address(usdc)), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_PreviewMatchesActualStable() public {
        _startPhase(0, LONG);

        (uint256 baseCon, uint256 bonusCon, uint8 newTier) = presale.previewPurchase(alice, 25_000 * 1e6);
        _buyStable(alice, usdc, 25_000 * 1e6);

        assertEq(presale.purchased(alice), baseCon + bonusCon);
        assertEq(presale.bonusTiersAwarded(alice), newTier);

        // A second preview accounts for the already-credited contribution.
        (uint256 baseCon2, uint256 bonusCon2, uint8 newTier2) = presale.previewPurchase(alice, 25_000 * 1e6);
        uint256 before = presale.purchased(alice);
        _buyStable(alice, usdc, 25_000 * 1e6);
        assertEq(presale.purchased(alice) - before, baseCon2 + bonusCon2);
        assertEq(presale.bonusTiersAwarded(alice), newTier2);
        assertEq(newTier2, 3);
    }

    function test_PreviewMatchesActualETH() public {
        _startPhase(0, LONG);
        uint256 usdE6 = (5 ether * uint256(ETH_PRICE)) / 1e20; // $10k

        (uint256 baseCon, uint256 bonusCon, uint8 newTier) = presale.previewPurchase(alice, usdE6);
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        presale.buyWithETH{value: 5 ether}();

        assertEq(presale.purchased(alice), baseCon + bonusCon);
        assertEq(presale.bonusTiersAwarded(alice), newTier);
    }

    function test_BonusTiersView() public view {
        (uint256[3] memory usd, uint256[3] memory con_) = presale.bonusTiers();
        assertEq(usd[0], 10_000 * 1e6);
        assertEq(usd[1], 25_000 * 1e6);
        assertEq(usd[2], 50_000 * 1e6);
        assertEq(con_[0], TIER1_CON);
        assertEq(con_[1], TIER2_CON);
        assertEq(con_[2], TIER3_CON);
    }

    function test_GlobalCapNeverExceededAndBlocksFurtherBuys() public {
        uint256[5] memory prices = [uint256(5000), 6000, 7000, 8000, 9000];
        for (uint8 i = 0; i < 5; ++i) {
            _startPhase(i, LONG);
            address whale = makeAddr(string(abi.encodePacked("whale", i)));
            // Enough to fill the 10M base cap at this phase price (and cross all bonus tiers).
            uint256 amount = 10_000_000 * prices[i];
            usdc.mint(whale, amount);
            vm.startPrank(whale);
            usdc.approve(address(presale), amount);
            presale.buyWithStable(IERC20(address(usdc)), amount);
            vm.stopPrank();
            assertLe(presale.totalSold(), PRESALE_CAP);
        }

        // base (5 x 10M would be 50M) + bonuses are clamped so the global cap is hit exactly.
        assertEq(presale.totalSold(), PRESALE_CAP);

        // The global cap now blocks any further purchase, even though phase 4 base has room.
        usdc.mint(bob, 1000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(presale), 1000 * 1e6);
        vm.expectRevert(Presale.PresaleCapReached.selector);
        presale.buyWithStable(IERC20(address(usdc)), 1000 * 1e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BuyStableKeepsInvariants(uint256 amount) public {
        _startPhase(0, LONG);
        // Bound to a sane range that produces >= 1 wei of CON and is well-funded.
        amount = bound(amount, 1, 200_000 * 1e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(presale), amount);

        uint256 conAmount = (amount * 1e18) / 5000;
        if (conAmount == 0) {
            vm.expectRevert(Presale.ZeroConAmount.selector);
            presale.buyWithStable(IERC20(address(usdc)), amount);
            vm.stopPrank();
            return;
        }
        presale.buyWithStable(IERC20(address(usdc)), amount);
        vm.stopPrank();

        // Invariants for a single buyer.
        assertEq(presale.purchased(alice), presale.totalSold());
        assertLe(_phaseSold(0), CAP);
        assertGe(con.balanceOf(address(presale)), presale.totalSold() - presale.totalClaimed());
    }

    function testFuzz_BuyETHKeepsInvariants(uint256 value) public {
        _startPhase(0, LONG);
        value = bound(value, 1, 100 ether);

        vm.deal(alice, value);
        uint256 usdE6 = (value * uint256(ETH_PRICE)) / 1e20;
        uint256 conAmount = (usdE6 * 1e18) / 5000;

        vm.prank(alice);
        if (conAmount == 0) {
            vm.expectRevert(Presale.ZeroConAmount.selector);
            presale.buyWithETH{value: value}();
            return;
        }
        presale.buyWithETH{value: value}();

        assertEq(presale.purchased(alice), presale.totalSold());
        assertLe(_phaseSold(0), CAP);
        assertGe(con.balanceOf(address(presale)), presale.totalSold() - presale.totalClaimed());
        // Contract never keeps more ETH than the exact cost of what was booked.
        assertLe(address(presale).balance, value);
    }
}
