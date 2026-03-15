// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MockERC20.sol";

contract MockSwapRouter {
    // simple swap: transfers `amountIn` of buyToken from this router to recipient
    function swap(address sellToken, address buyToken, uint256 amountIn, uint256 /*minOut*/, address recipient) external returns (uint256 amountOut) {
        // for simplicity, 1:1 swap rate
        MockERC20(buyToken).transfer(recipient, amountIn);
        return amountIn;
    }

    // helper to fund router with tokens
    function fund(address token, address from, uint256 amount) external {
        MockERC20(token).transferFrom(from, address(this), amount);
    }
}
