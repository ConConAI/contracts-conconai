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
///         Buyers also earn one-time, stacking purchase bonuses (see {bonusTiers}); bonuses are pure
///         internal bookings (no external call) and, together with base sales, can never push
///         `totalSold` above {PRESALE_CAP}. A professional security audit is required before mainnet.
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

    /// @notice Hard global cap on total booked CON (base + stacking bonuses), 18 decimals.
    /// @dev `totalSold` (base + bonus) can never exceed this; the deployer funds the presale with
    ///      exactly this amount so every booked allocation (including bonuses) is claimable.
    uint256 public constant PRESALE_CAP = 50_000_000 * 1e18;

    /// @notice Number of one-time, stacking purchase-bonus tiers.
    uint8 public constant NUM_BONUS_TIERS = 3;

    /// @notice Cumulative USD(1e6) a buyer must contribute to unlock bonus tier 1 / 2 / 3.
    uint256 internal constant BONUS_TIER1_USD = 10_000 * 1e6;
    uint256 internal constant BONUS_TIER2_USD = 25_000 * 1e6;
    uint256 internal constant BONUS_TIER3_USD = 50_000 * 1e6;

    /// @notice Extra CON(1e18) granted when a buyer first crosses bonus tier 1 / 2 / 3 (each once).
    /// @dev Stacking: reaching $50k yields 50k + 150k + 400k = 600,000 CON in total bonuses.
    uint256 internal constant BONUS_TIER1_CON = 50_000 * 1e18;
    uint256 internal constant BONUS_TIER2_CON = 150_000 * 1e18;
    uint256 internal constant BONUS_TIER3_CON = 400_000 * 1e18;

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

    /// @notice CON already claimed by each buyer (18 decimals); lets the frontend distinguish
    ///         "claimable" (`purchased > 0`) from "already claimed" (`claimed > 0 && purchased == 0`).
    /// @dev Informational mirror of claims; does not affect any accounting.
    mapping(address buyer => uint256 amount) public claimed;

    /// @notice Total CON booked across all buyers and phases.
    uint256 public totalSold;

    /// @notice Total CON already claimed by buyers.
    uint256 public totalClaimed;

    /// @notice Cumulative USD(1e6) each buyer has actually paid in (stables 1:1, ETH via the oracle).
    /// @dev Drives the stacking bonus tiers; only the amount actually charged is counted.
    mapping(address buyer => uint256 usdE6) public contributedUsd;

    /// @notice Number of bonus tiers already awarded to each buyer (0..{NUM_BONUS_TIERS}).
    /// @dev Monotonic; ensures each tier is granted at most once per buyer.
    mapping(address buyer => uint8 tiers) public bonusTiersAwarded;

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

    /// @notice Emitted when a buyer crosses one or more stacking bonus tiers.
    /// @param buyer The purchaser receiving the bonus.
    /// @param bonusCon Extra CON booked for the newly crossed tier(s) (after any global-cap clamp).
    /// @param newTier The buyer's bonus tier count after this award (0..{NUM_BONUS_TIERS}).
    event BonusAwarded(address indexed buyer, uint256 bonusCon, uint8 newTier);

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
    error ZeroDuration();
    error PhaseNotStarted();
    error PresaleIsEnded();
    error PhaseExpired();
    error PhaseSoldOut();
    error PresaleCapReached();
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
    error PresaleNotEnded();
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

        uint256 remaining = _baseRemaining(phase);

        uint256 charge = amount;
        if (conAmount > remaining) {
            conAmount = remaining;
            // Exact stablecoin cost for the clamped CON amount (floor); never over-charges.
            charge = (conAmount * price) / CON_SCALE;
        }
        if (conAmount == 0) revert ZeroConAmount();

        _book(msg.sender, phaseIndex, conAmount);
        emit Purchased(msg.sender, phaseIndex, conAmount, address(stable), charge);

        // Stables are 1:1 USD with 6 decimals, so the charged amount IS the USD(1e6) contributed.
        _awardBonus(msg.sender, charge);

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

        uint256 remaining = _baseRemaining(phase);
        bool clamped = conAmount > remaining; // L-02: capture before clamping
        if (clamped) {
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

        // L-02: credit the full USD value of the ETH when unclamped (floor rounding on the
        // CON->USD step must not drop a buyer a micro-dollar below a bonus tier); when clamped,
        // credit the exact USD charged for the booked CON.
        _awardBonus(msg.sender, clamped ? requiredUsdE6 : usdE6);

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
        claimed[msg.sender] += amount;
        totalClaimed += amount;

        emit Claimed(msg.sender, amount);
        CON_TOKEN.safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Start (or restart) a phase, activating it and setting its timer.
    /// @dev The owner may activate ANY valid phase index (0..{NUM_PHASES}-1) in any order, allowing
    ///      free switching (forward or backward). Cannot be called once the presale has ended.
    /// @param i Phase index to start (any valid index `0..NUM_PHASES-1`).
    /// @param duration Seconds from now until the phase closes.
    function startPhase(uint8 i, uint64 duration) external onlyOwner {
        if (presaleEnded) revert PresaleIsEnded();
        if (i >= NUM_PHASES) revert InvalidPhaseIndex();
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
        // L-01: mark already-expired (nowTs - 1) so a buy in THIS block can no longer slip in at the
        // old phase price. nowTs is always far greater than 1, so this cannot underflow.
        phase.endsAt = nowTs - 1;
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
    /// @dev Excess = `balanceOf(this) - (totalSold - totalClaimed)`. Only callable once the presale has
    ///      ended (so buying can no longer create new claims after a sweep). Reverts if there is nothing
    ///      to sweep, guaranteeing outstanding claims remain fully backed.
    function sweepUnsold() external onlyOwner nonReentrant {
        if (!presaleEnded) revert PresaleNotEnded();
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

    /// @notice Remaining CON sellable in the active phase, clamped to the global cap.
    /// @dev Returns the minimum of the phase remaining (`phase.cap - phase.sold`) and the global
    ///      remaining (`PRESALE_CAP - totalSold`, which already accounts for bonuses).
    /// @return The CON still sellable right now (18 decimals).
    function remainingInActivePhase() external view returns (uint256) {
        Phase storage phase = phases[currentPhase];
        uint256 phaseRemaining = phase.cap - phase.sold;
        uint256 globalRemaining = PRESALE_CAP - totalSold;
        return phaseRemaining < globalRemaining ? phaseRemaining : globalRemaining;
    }

    /// @notice Whether buying is currently possible in the active phase.
    /// @return active True if a buy would be accepted right now.
    function isBuyingActive() external view returns (bool active) {
        Phase storage phase = phases[currentPhase];
        // forge-lint: disable-next-line(block-timestamp) - timed phase window is intentional.
        return phase.started && !presaleEnded && !paused() && block.timestamp <= phase.endsAt && phase.sold < phase.cap
            && totalSold < PRESALE_CAP;
    }

    /// @notice Preview the base + stacking-bonus CON a buyer would receive for spending `usdE6`.
    /// @dev Pure view (no state change). Mirrors the buy path: base is priced at the current phase
    ///      price and clamped to the phase and global caps; only the USD actually charged drives the
    ///      one-time, stacking bonus, which is itself clamped to the remaining global cap.
    /// @param buyer The buyer whose existing contribution/awarded tiers are considered.
    /// @param usdE6 The USD amount to spend, scaled by 1e6 (for ETH, pass the oracle-derived USD).
    /// @return baseCon Base CON booked for the spend (18 decimals), after cap clamping.
    /// @return bonusCon Extra CON from any newly crossed bonus tiers (18 decimals).
    /// @return newTier The buyer's resulting bonus tier count (0..{NUM_BONUS_TIERS}).
    function previewPurchase(address buyer, uint256 usdE6)
        external
        view
        returns (uint256 baseCon, uint256 bonusCon, uint8 newTier)
    {
        Phase storage phase = phases[currentPhase];
        uint256 price = phase.priceUsdE6;

        baseCon = (usdE6 * CON_SCALE) / price;

        uint256 phaseRemaining = phase.cap - phase.sold;
        uint256 globalRemaining = PRESALE_CAP - totalSold;
        uint256 remaining = phaseRemaining < globalRemaining ? phaseRemaining : globalRemaining;

        uint256 chargedUsdE6 = usdE6;
        if (baseCon > remaining) {
            baseCon = remaining;
            chargedUsdE6 = (baseCon * price) / CON_SCALE;
        }

        uint8 awarded = bonusTiersAwarded[buyer];
        newTier = _tiersFor(contributedUsd[buyer] + chargedUsdE6);
        if (newTier > awarded) {
            for (uint8 t = awarded; t < newTier; ++t) {
                bonusCon += _tierCon(t);
            }
            uint256 remainingAfterBase = globalRemaining - baseCon;
            if (bonusCon > remainingAfterBase) bonusCon = remainingAfterBase;
        }
    }

    /// @notice The bonus-tier thresholds and amounts.
    /// @return usdThresholds Cumulative USD(1e6) needed to unlock each tier.
    /// @return conAmounts Extra CON(1e18) granted for crossing each tier.
    function bonusTiers()
        external
        pure
        returns (uint256[NUM_BONUS_TIERS] memory usdThresholds, uint256[NUM_BONUS_TIERS] memory conAmounts)
    {
        usdThresholds = [BONUS_TIER1_USD, BONUS_TIER2_USD, BONUS_TIER3_USD];
        conAmounts = [BONUS_TIER1_CON, BONUS_TIER2_CON, BONUS_TIER3_CON];
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

    /// @dev Applies the booking effects for a base purchase (no external interaction).
    function _book(address buyer, uint8 phaseIndex, uint256 conAmount) internal {
        purchased[buyer] += conAmount;
        phases[phaseIndex].sold += conAmount;
        totalSold += conAmount;
    }

    /// @dev CON still sellable as *base* right now: min of the phase cap and the global cap.
    ///      Reverts if either the phase ({PhaseSoldOut}) or the presale ({PresaleCapReached}) is full.
    function _baseRemaining(Phase storage phase) internal view returns (uint256 remaining) {
        uint256 phaseRemaining = phase.cap - phase.sold;
        if (phaseRemaining == 0) revert PhaseSoldOut();
        uint256 globalRemaining = PRESALE_CAP - totalSold;
        if (globalRemaining == 0) revert PresaleCapReached();
        remaining = phaseRemaining < globalRemaining ? phaseRemaining : globalRemaining;
    }

    /// @dev Credits `usdE6Added` to the buyer's running total and books any newly crossed bonus
    ///      tiers. Pure internal booking: bonuses go to `purchased`/`totalSold` only (never a phase
    ///      cap) and are clamped to the remaining global cap. No external interaction (CEI-safe).
    function _awardBonus(address buyer, uint256 usdE6Added) internal {
        uint256 contributed = contributedUsd[buyer] + usdE6Added;
        contributedUsd[buyer] = contributed;

        uint8 awarded = bonusTiersAwarded[buyer];
        uint8 reached = _tiersFor(contributed);
        if (reached <= awarded) return;

        uint256 bonus;
        for (uint8 t = awarded; t < reached; ++t) {
            bonus += _tierCon(t);
        }

        // Bonuses count against the global cap only; clamp near sellout so totalSold <= PRESALE_CAP.
        uint256 globalRemaining = PRESALE_CAP - totalSold;
        if (bonus > globalRemaining) bonus = globalRemaining;

        bonusTiersAwarded[buyer] = reached;
        if (bonus > 0) {
            purchased[buyer] += bonus;
            totalSold += bonus;
        }
        emit BonusAwarded(buyer, bonus, reached);
    }

    /// @dev Number of bonus tiers unlocked by a cumulative contribution of `usdE6` (0..3).
    function _tiersFor(uint256 usdE6) internal pure returns (uint8 tiers) {
        if (usdE6 >= BONUS_TIER3_USD) return 3;
        if (usdE6 >= BONUS_TIER2_USD) return 2;
        if (usdE6 >= BONUS_TIER1_USD) return 1;
        return 0;
    }

    /// @dev Bonus CON granted for crossing the tier at `tierIndex` (0-based).
    function _tierCon(uint8 tierIndex) internal pure returns (uint256) {
        if (tierIndex == 0) return BONUS_TIER1_CON;
        if (tierIndex == 1) return BONUS_TIER2_CON;
        return BONUS_TIER3_CON;
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
