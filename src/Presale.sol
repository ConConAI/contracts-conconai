// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title Presale
/// @author ConConAI
/// @notice Phased presale for the already-deployed $CON token. Buyers pay in USDC, USDT or ETH and
///         their $CON allocation is *booked* (no token transfer at purchase). After the presale the
///         admin opens claiming and buyers withdraw their allocation.
/// @dev    Audit-clean by construction:
///         - Immutable config (token, stables, oracle, treasury); NO setters for them.
///         - Custom errors only, events on every state change, strict CEI, pull-pattern claim.
///         - `ReentrancyGuard` on all value-moving entry points, `SafeERC20` everywhere.
///         - One-way `presaleEnded` / `claimOpen` flags that the owner can never unset.
///         - The owner can never mutate `purchased`, reverse a claim, or touch buyers' $CON.
///         A professional security audit is required before mainnet use.
contract Presale is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice A single presale phase.
    /// @param priceUsdE6 Price per 1 CON in USD, scaled by 1e6 (e.g. $0.005 == 5000).
    /// @param cap Maximum amount of CON (18 decimals) sellable in this phase.
    /// @param sold Amount of CON (18 decimals) already booked in this phase.
    /// @param started Whether the admin has started this phase.
    /// @param endsAt Unix timestamp after which buying in this phase is closed.
    struct Phase {
        uint256 priceUsdE6;
        uint256 cap;
        uint256 sold;
        bool started;
        uint64 endsAt;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of presale phases.
    uint8 public constant NUM_PHASES = 5;

    /// @notice CON cap per phase: 10,000,000 CON (18 decimals).
    uint256 public constant PHASE_CAP = 10_000_000 * 1e18;

    /// @notice USD scaling factor (1 USD == 1e6), matching 6-decimal stablecoins.
    uint256 internal constant USD_SCALE = 1e6;

    /// @notice CON has 18 decimals; used to scale conAmount math.
    uint256 internal constant CON_SCALE = 1e18;

    /// @notice Expected decimals of the Chainlink ETH/USD feed (standard USD feeds use 8).
    uint8 internal constant FEED_DECIMALS = 8;

    /// @notice Combined scale to convert `wei * answer(1e8)` into a USD(1e6) amount: 1e8 * 1e12.
    uint256 internal constant ETH_USD_SCALE = 1e20;

    /// @notice Maximum accepted age of an oracle answer (Chainlink ETH/USD mainnet heartbeat).
    /// @dev Re-verify against the live feed's heartbeat before mainnet.
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice The already-deployed $CON token this presale books and pays out.
    IERC20 public immutable CON_TOKEN;

    /// @notice USDC payment token (6 decimals, 1:1 USD).
    IERC20 public immutable USDC;

    /// @notice USDT payment token (6 decimals, 1:1 USD).
    IERC20 public immutable USDT;

    /// @notice Chainlink ETH/USD price feed.
    IAggregatorV3 public immutable ETH_USD_FEED;

    /// @notice Treasury that receives raised funds and swept/unsold $CON (equals the owner/admin).
    address public immutable TREASURY;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The five presale phases, indexed 0..4.
    Phase[NUM_PHASES] public phases;

    /// @notice Index of the currently active phase.
    uint8 public currentPhase;

    /// @notice One-way flag: once true, no further buying is possible in any phase.
    bool public presaleEnded;

    /// @notice One-way flag: once true, buyers may claim their booked allocation.
    bool public claimOpen;

    /// @notice Booked CON allocation per buyer (18 decimals); set to 0 on claim.
    mapping(address buyer => uint256 conAmount) public purchased;

    /// @notice Total CON booked across all buyers and phases.
    uint256 public totalSold;

    /// @notice Total CON already claimed by buyers.
    uint256 public totalClaimed;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a buyer books an allocation.
    /// @param buyer The purchaser.
    /// @param phaseIndex The phase the purchase was booked in.
    /// @param conAmount CON amount booked (18 decimals).
    /// @param asset Payment asset (address(0) for ETH).
    /// @param paid Amount of `asset` charged.
    event Purchased(
        address indexed buyer, uint8 indexed phaseIndex, uint256 conAmount, address indexed asset, uint256 paid
    );

    /// @notice Emitted when a buyer claims their allocation.
    event Claimed(address indexed buyer, uint256 conAmount);

    /// @notice Emitted when the admin starts a phase.
    event PhaseStarted(uint8 indexed phaseIndex, uint256 priceUsdE6, uint64 endsAt);

    /// @notice Emitted when the active phase timer is changed.
    event TimerSet(uint8 indexed phaseIndex, uint64 endsAt);

    /// @notice Emitted when the active phase is closed early.
    event PhaseEnded(uint8 indexed phaseIndex, uint64 endsAt);

    /// @notice Emitted when the presale is permanently ended.
    event PresaleEnded();

    /// @notice Emitted when claiming is permanently enabled.
    event ClaimEnabled();

    /// @notice Emitted when raised funds are withdrawn to the treasury.
    event Withdrawn(address indexed asset, uint256 amount);

    /// @notice Emitted when excess (unsold) $CON is swept to the treasury.
    event Swept(uint256 conAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidPhaseIndex();
    error NonSequentialPhase();
    error ZeroDuration();
    error PhaseNotStarted();
    error PresaleIsEnded();
    error PhaseExpired();
    error PhaseSoldOut();
    error UnsupportedStable();
    error ZeroConAmount();
    error ZeroPayment();
    error ClaimNotOpen();
    error ClaimAlreadyOpen();
    error NothingToClaim();
    error OracleInvalidPrice();
    error OracleStale();
    error OracleRoundIncomplete();
    error InvalidFeedDecimals();
    error CannotWithdrawConToken();
    error NothingToWithdraw();
    error NothingToSweep();
    error EthTransferFailed();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the presale bound to the existing $CON token and fixed phase prices.
    /// @dev Reverts ({ZeroAddress}) if any address is zero and ({InvalidFeedDecimals}) if the feed
    ///      does not report 8 decimals. Phase prices are fixed at $0.005..$0.009 and have no setter.
    /// @param conToken The already-deployed $CON token.
    /// @param usdc USDC payment token (6 decimals).
    /// @param usdt USDT payment token (6 decimals).
    /// @param ethUsdFeed Chainlink ETH/USD aggregator.
    /// @param treasury Treasury and initial owner/admin (receives funds and unsold $CON).
    constructor(IERC20 conToken, IERC20 usdc, IERC20 usdt, IAggregatorV3 ethUsdFeed, address treasury)
        Ownable(treasury)
    {
        if (
            address(conToken) == address(0) || address(usdc) == address(0) || address(usdt) == address(0)
                || address(ethUsdFeed) == address(0) || treasury == address(0)
        ) {
            revert ZeroAddress();
        }
        if (ethUsdFeed.decimals() != FEED_DECIMALS) {
            revert InvalidFeedDecimals();
        }

        CON_TOKEN = conToken;
        USDC = usdc;
        USDT = usdt;
        ETH_USD_FEED = ethUsdFeed;
        TREASURY = treasury;

        // Fixed phase prices: $0.005, $0.006, $0.007, $0.008, $0.009 (1e6 USD scale).
        uint256[NUM_PHASES] memory prices = [uint256(5000), 6000, 7000, 8000, 9000];
        for (uint8 i = 0; i < NUM_PHASES; ++i) {
            phases[i].priceUsdE6 = prices[i];
            phases[i].cap = PHASE_CAP;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  BUY
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy (book) $CON with a supported stablecoin (USDC or USDT).
    /// @dev Books the allocation; no $CON is transferred until {claim}. If the purchase would
    ///      exceed the phase cap, the CON amount is clamped to the remaining cap and only the exact
    ///      cost of that clamped amount is charged. CEI: state is updated before the token pull.
    /// @param stable The payment token; must equal {USDC} or {USDT}.
    /// @param amount The stablecoin amount to spend (6 decimals).
    function buyWithStable(IERC20 stable, uint256 amount) external nonReentrant whenNotPaused {
        if (stable != USDC && stable != USDT) revert UnsupportedStable();
        if (amount == 0) revert ZeroPayment();

        uint8 phaseIndex = currentPhase;
        Phase storage phase = _activePhase(phaseIndex);

        uint256 price = phase.priceUsdE6;
        uint256 conAmount = (amount * CON_SCALE) / price;

        uint256 remaining = phase.cap - phase.sold;
        if (remaining == 0) revert PhaseSoldOut();

        uint256 charge = amount;
        if (conAmount > remaining) {
            conAmount = remaining;
            // Exact stablecoin cost for the clamped CON amount (floor); never over-charges.
            charge = (conAmount * price) / CON_SCALE;
        }
        if (conAmount == 0) revert ZeroConAmount();

        _book(msg.sender, phaseIndex, conAmount);
        emit Purchased(msg.sender, phaseIndex, conAmount, address(stable), charge);

        stable.safeTransferFrom(msg.sender, address(this), charge);
    }

    /// @notice Buy (book) $CON with ETH, priced via the Chainlink ETH/USD feed.
    /// @dev Books the allocation; no $CON is transferred until {claim}. The CON amount is clamped to
    ///      the remaining cap, only the exact ETH cost is kept, and any excess ETH is refunded after
    ///      state updates (CEI) under the reentrancy guard.
    function buyWithETH() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroPayment();

        uint8 phaseIndex = currentPhase;
        Phase storage phase = _activePhase(phaseIndex);

        uint256 price = phase.priceUsdE6;
        uint256 ethUsd = _readEthUsd();

        // USD(1e6) value of msg.value, then CON(1e18) at the phase price.
        uint256 usdE6 = (msg.value * ethUsd) / ETH_USD_SCALE;
        uint256 conAmount = (usdE6 * CON_SCALE) / price;

        uint256 remaining = phase.cap - phase.sold;
        if (remaining == 0) revert PhaseSoldOut();
        if (conAmount > remaining) {
            conAmount = remaining;
        }
        if (conAmount == 0) revert ZeroConAmount();

        // Exact ETH cost of the (possibly clamped) CON amount; refund the remainder.
        uint256 requiredUsdE6 = (conAmount * price) / CON_SCALE;
        uint256 requiredEth = (requiredUsdE6 * ETH_USD_SCALE) / ethUsd;
        // Defensive: rounding can never make the requirement exceed what was sent.
        if (requiredEth > msg.value) {
            requiredEth = msg.value;
        }
        uint256 refund = msg.value - requiredEth;

        _book(msg.sender, phaseIndex, conAmount);
        emit Purchased(msg.sender, phaseIndex, conAmount, address(0), requiredEth);

        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim the caller's booked $CON allocation once claiming is open.
    /// @dev Pull-pattern, CEI, reentrancy-guarded and double-claim safe (allocation zeroed first).
    function claim() external nonReentrant {
        if (!claimOpen) revert ClaimNotOpen();

        uint256 amount = purchased[msg.sender];
        if (amount == 0) revert NothingToClaim();

        purchased[msg.sender] = 0;
        totalClaimed += amount;

        emit Claimed(msg.sender, amount);
        CON_TOKEN.safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Start (or restart) a phase, activating it and setting its timer.
    /// @dev Phases must advance sequentially: `i` may equal the current phase or the next one. Cannot
    ///      be called once the presale has ended.
    /// @param i Phase index to start (must be `currentPhase` or `currentPhase + 1`).
    /// @param duration Seconds from now until the phase closes.
    function startPhase(uint8 i, uint64 duration) external onlyOwner {
        if (presaleEnded) revert PresaleIsEnded();
        if (i >= NUM_PHASES) revert InvalidPhaseIndex();
        if (i != currentPhase && i != currentPhase + 1) revert NonSequentialPhase();
        if (duration == 0) revert ZeroDuration();

        // forge-lint: disable-next-line(unsafe-typecast) - block.timestamp fits in uint64 for millennia.
        uint64 endsAt = uint64(block.timestamp) + duration;
        phases[i].started = true;
        phases[i].endsAt = endsAt;
        currentPhase = i;

        emit PhaseStarted(i, phases[i].priceUsdE6, endsAt);
    }

    /// @notice Set the active phase's end timestamp directly.
    /// @param newEndsAt New end timestamp for the active phase.
    function setTimer(uint64 newEndsAt) external onlyOwner {
        Phase storage phase = phases[currentPhase];
        if (!phase.started) revert PhaseNotStarted();
        phase.endsAt = newEndsAt;
        emit TimerSet(currentPhase, newEndsAt);
    }

    /// @notice Extend the active phase's timer by a number of seconds.
    /// @param extraSeconds Seconds to add to the active phase's end timestamp.
    function extendTimer(uint64 extraSeconds) external onlyOwner {
        Phase storage phase = phases[currentPhase];
        if (!phase.started) revert PhaseNotStarted();
        uint64 newEndsAt = phase.endsAt + extraSeconds;
        phase.endsAt = newEndsAt;
        emit TimerSet(currentPhase, newEndsAt);
    }

    /// @notice Close the active phase immediately by setting its timer to now.
    function endPhase() external onlyOwner {
        Phase storage phase = phases[currentPhase];
        if (!phase.started) revert PhaseNotStarted();
        // forge-lint: disable-next-line(unsafe-typecast) - block.timestamp fits in uint64 for millennia.
        uint64 nowTs = uint64(block.timestamp);
        phase.endsAt = nowTs;
        emit PhaseEnded(currentPhase, nowTs);
    }

    /// @notice Permanently end the presale; no further buying is possible. One-way.
    function endPresale() external onlyOwner {
        if (presaleEnded) revert PresaleIsEnded();
        presaleEnded = true;
        emit PresaleEnded();
    }

    /// @notice Permanently enable claiming. One-way and independent of {endPresale}.
    function enableClaim() external onlyOwner {
        if (claimOpen) revert ClaimAlreadyOpen();
        claimOpen = true;
        emit ClaimEnabled();
    }

    /// @notice Pause buying (claims remain enabled).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause buying.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraw raised funds to the treasury.
    /// @dev `asset == address(0)` withdraws ETH; otherwise withdraws the full balance of `asset`.
    ///      Reverts if `asset` is the $CON token (buyers' tokens are never withdrawable this way).
    /// @param asset The asset to withdraw (address(0) for ETH).
    function withdraw(address asset) external onlyOwner nonReentrant {
        if (asset == address(CON_TOKEN)) revert CannotWithdrawConToken();

        if (asset == address(0)) {
            uint256 amount = address(this).balance;
            if (amount == 0) revert NothingToWithdraw();
            emit Withdrawn(asset, amount);
            (bool ok,) = TREASURY.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            uint256 amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) revert NothingToWithdraw();
            emit Withdrawn(asset, amount);
            IERC20(asset).safeTransfer(TREASURY, amount);
        }
    }

    /// @notice Sweep only the EXCESS (unsold) $CON to the treasury, always leaving claimers covered.
    /// @dev Excess = `balanceOf(this) - (totalSold - totalClaimed)`. Reverts if there is nothing to
    ///      sweep, guaranteeing outstanding claims remain fully backed.
    function sweepUnsold() external onlyOwner nonReentrant {
        uint256 outstanding = totalSold - totalClaimed;
        uint256 balance = CON_TOKEN.balanceOf(address(this));
        if (balance <= outstanding) revert NothingToSweep();

        uint256 excess = balance - outstanding;
        emit Swept(excess);
        CON_TOKEN.safeTransfer(TREASURY, excess);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Outstanding (booked but unclaimed) $CON that the contract must keep covered.
    /// @return The amount of CON owed to buyers who have not yet claimed.
    function outstandingClaims() external view returns (uint256) {
        return totalSold - totalClaimed;
    }

    /// @notice Remaining CON sellable in the active phase.
    /// @return The active phase's remaining cap (18 decimals).
    function remainingInActivePhase() external view returns (uint256) {
        Phase storage phase = phases[currentPhase];
        return phase.cap - phase.sold;
    }

    /// @notice Whether buying is currently possible in the active phase.
    /// @return active True if a buy would be accepted right now.
    function isBuyingActive() external view returns (bool active) {
        Phase storage phase = phases[currentPhase];
        // forge-lint: disable-next-line(block-timestamp) - timed phase window is intentional.
        return phase.started && !presaleEnded && !paused() && block.timestamp <= phase.endsAt && phase.sold < phase.cap;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the active phase storage pointer after enforcing that buying is allowed.
    function _activePhase(uint8 phaseIndex) internal view returns (Phase storage phase) {
        if (presaleEnded) revert PresaleIsEnded();
        phase = phases[phaseIndex];
        if (!phase.started) revert PhaseNotStarted();
        // forge-lint: disable-next-line(block-timestamp) - timed phase window is intentional.
        if (block.timestamp > phase.endsAt) revert PhaseExpired();
    }

    /// @dev Applies the booking effects for a purchase (no external interaction).
    function _book(address buyer, uint8 phaseIndex, uint256 conAmount) internal {
        purchased[buyer] += conAmount;
        phases[phaseIndex].sold += conAmount;
        totalSold += conAmount;
    }

    /// @dev Reads and validates the ETH/USD price (8-decimal answer), reverting on bad/stale data.
    /// @return ethUsd The validated ETH/USD price (8 decimals).
    function _readEthUsd() internal view returns (uint256 ethUsd) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ETH_USD_FEED.latestRoundData();
        if (answer <= 0) revert OracleInvalidPrice();
        if (updatedAt == 0) revert OracleRoundIncomplete();
        if (answeredInRound < roundId) revert OracleRoundIncomplete();
        // forge-lint: disable-next-line(block-timestamp) - staleness guard is the intended use.
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) revert OracleStale();
        // forge-lint: disable-next-line(unsafe-typecast) - answer is guaranteed > 0 by the check above.
        ethUsd = uint256(answer);
    }
}
