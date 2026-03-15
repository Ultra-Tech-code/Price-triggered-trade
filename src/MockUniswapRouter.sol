// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MockERC20.sol";

contract MockUniswapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    // simple exactInputSingle mock: transfers amountIn of tokenOut from router to recipient at 1:1 rate
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        // send tokenOut to recipient
        MockERC20(params.tokenOut).transfer(params.recipient, params.amountIn);
        return params.amountIn;
    }
}
