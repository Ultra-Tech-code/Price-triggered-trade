// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "forge-std/Test.sol";
// import "../src/PriceVault.sol";
// import "../src/MockERC20.sol";
// import "@chainlink/contracts/tests/MockV3Aggregator.sol";
// import "../src/MockUniswapRouter.sol";

// contract PriceVaultTest is Test {
//     PriceVault vault;
//     MockERC20 tokenA;
//     MockERC20 tokenB;
//     MockV3Aggregator feed;
//     MockUniswapRouter router;

//     function setUp() public {
//         vault = new PriceVault();
//         tokenA = new MockERC20("TokenA", "TKA", 18);
//         tokenB = new MockERC20("TokenB", "TKB", 18);
//         tokenA.mint(address(this), 1_000_000 ether);
//         feed = new MockV3Aggregator(8, 200);
//         router = new MockUniswapRouter();
//         // fund router with buy token
//         tokenB.mint(address(router), 1_000_000 ether);
//         vault.setSwapRouter(address(router));
//     }

//     function testCreateAndCancelOrder() public {
//         // approve vault to pull tokens
//         tokenA.approve(address(vault), 100 ether);
//         uint256 orderId = vault.createOrder(address(tokenA), address(tokenB), address(feed), 100 ether, 150, PriceVault.TriggerType.Above, PriceVault.OrderKind.Limit, 0, 100);
//         uint256[] memory orders = vault.getUserOrders(address(this));
//         assertEq(orders.length, 1);
//         assertEq(orders[0], orderId);

//         // cancel
//         vault.cancelOrder(orderId);
//         // after cancel, executing should revert
//         vm.expectRevert("not active");
//         vault.executeOrder(orderId);
//     }

//     function testExecuteOrderSwaps() public {
//         // approve vault to pull tokens
//         tokenA.approve(address(vault), 100 ether);

//         // router already funded in setUp

//         uint256 orderId = vault.createOrder(address(tokenA), address(tokenB), address(feed), 100 ether, 150, PriceVault.TriggerType.Above, PriceVault.OrderKind.Limit, 0, 100);

//         // feed currently 200 > 150 so execution allowed
//         vault.executeOrder(orderId);

//         // owner (this) should receive tokenB from router
//         assertEq(tokenB.balanceOf(address(this)), 100 ether);
//     }
// }
