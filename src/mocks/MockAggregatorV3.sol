// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title MockAggregatorV3 (TESTNET ONLY)
/// @author ConConAI
/// @notice A configurable Chainlink-style ETH/USD aggregator (8 decimals) for Sepolia testing.
/// @dev    TESTNET ONLY. The price and timestamp are settable by anyone and MUST NEVER be used in
///         production. It lets you drive the presale's ETH pricing and oracle guards on a testnet.
///         {latestRoundData} always reports a complete round (`answeredInRound == roundId`).
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 private constant FEED_DECIMALS = 8;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    /// @notice Emitted when the answer is updated.
    event AnswerSet(int256 answer, uint80 roundId, uint256 updatedAt);

    /// @notice Emitted when the updatedAt timestamp is overridden.
    event UpdatedAtSet(uint256 updatedAt);

    /// @param initialAnswer The seed ETH/USD price (8 decimals, e.g. 3000e8).
    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    /// @inheritdoc IAggregatorV3
    function decimals() external pure override returns (uint8) {
        return FEED_DECIMALS;
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice Set a new ETH/USD price; starts a fresh, complete round at the current block time.
    /// @param newAnswer The new price (8 decimals).
    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _roundId += 1;
        emit AnswerSet(newAnswer, _roundId, _updatedAt);
    }

    /// @notice Override the `updatedAt` timestamp (e.g. to simulate a stale feed).
    /// @param newUpdatedAt The timestamp to report.
    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
        emit UpdatedAtSet(newUpdatedAt);
    }
}
