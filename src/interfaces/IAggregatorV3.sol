// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAggregatorV3
/// @notice Minimal Chainlink AggregatorV3 interface used by {Presale} to read the ETH/USD price.
/// @dev Matches the canonical Chainlink `AggregatorV3Interface`. Only the members consumed by the
///      presale are declared here to avoid pulling in an extra dependency.
interface IAggregatorV3 {
    /// @notice Number of decimals in the answer returned by {latestRoundData}.
    function decimals() external view returns (uint8);

    /// @notice Latest round data for the feed.
    /// @return roundId The round ID.
    /// @return answer The price answer for the round (for an ETH/USD feed: USD per ETH).
    /// @return startedAt Timestamp when the round started.
    /// @return updatedAt Timestamp when the round was last updated (used for the staleness guard).
    /// @return answeredInRound The round in which the answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
