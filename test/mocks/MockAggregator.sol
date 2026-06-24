// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title MockAggregator
/// @notice Configurable Chainlink-style aggregator for tests. Lets each test drive the answer,
///         timestamps and round IDs to exercise the presale's oracle guards.
contract MockAggregator is IAggregatorV3 {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint80 private _answeredInRound;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
}
