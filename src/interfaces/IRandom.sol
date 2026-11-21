// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A source of verifiable randomness. CrateBox only talks to this interface,
/// so StockBox can use drand on Robinhood Chain (or Pyth Entropy if it becomes available).
interface IRandomSource {
    /// @notice Native fee (wei) the caller must send to request one random number
    /// whose callback may use up to `gasLimit` gas.
    function fee(uint32 gasLimit) external view returns (uint256);

    /// @notice Request one random number. The source later calls
    /// IRandomConsumer(msg.sender).onRandom(requestId, seed).
    function request(uint32 gasLimit) external payable returns (uint256 requestId);
}

interface IRandomConsumer {
    function onRandom(uint256 requestId, bytes32 seed) external;
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
