// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockPriceFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 _initial) {
        answer = _initial;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _a) external {
        answer = _a;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 _answer,
            uint256 startedAt,
            uint256 _updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, answer, 0, updatedAt, 0);
    }
}
