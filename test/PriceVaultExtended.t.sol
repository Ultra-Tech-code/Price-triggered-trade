// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/PriceVault.sol";
import "../src/MockERC20.sol";
import "../src/MockUniswapRouter.sol";

contract LocalMockV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals = 8;

    constructor(int256 _initial) {
        answer = _initial;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _a) external {
        answer = _a;
        updatedAt = block.timestamp;
    }

    function setRoundData(int256 _a, uint256 _updatedAt) external {
        answer = _a;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

contract PriceVaultExtendedTest is Test {
    PriceVault vault;
    MockERC20 tokenA;
    MockERC20 tokenB;
    LocalMockV3 feed;
    MockUniswapRouter router;

    address owner;

    function setUp() public {
        owner = address(this);
        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        // mint tokens to test account
        tokenA.mint(owner, 1_000_000 ether);
        tokenB.mint(owner, 1_000_000 ether);

        // feed price > trigger by default
        feed = new LocalMockV3(200);

        // setup router and fund it with buy token
        router = new MockUniswapRouter();
        tokenB.transfer(address(router), 1_000_000 ether);
        vault = new PriceVault(address(router));
    }

    function _createLimitOrder(uint256 triggerPrice) internal returns (uint256) {
        tokenA.approve(address(vault), 100 ether);
        return vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            100 ether,
            triggerPrice,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            0,
            100
        );
    }

    function _createDcaOrder(uint256 totalAmount, uint256 amountPerSwap, uint64 cadence)
        internal
        returns (uint256)
    {
        tokenA.approve(address(vault), totalAmount);
        return vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            totalAmount,
            amountPerSwap,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.DCA,
            3000,
            cadence,
            100
        );
    }

    function test_checkUpkeep_and_perform_executes_order() public {
        // approve vault
        tokenA.approve(address(vault), 100 ether);

        // create order (priceTrigger 150, feed currently 200 so should be executable)
        uint256 orderId = vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            100 ether,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            0,
            100
        );

        // check upkeep
        (bool ok, bytes memory data) = vault.checkUpkeep(abi.encode(0)); // check data ignored by implementation
        assertTrue(ok, "checkUpkeep should return true");

        // decode performData (should be encoded order id)
        uint256 decodedId = abi.decode(data, (uint256));
        assertEq(decodedId, orderId);

        // perform upkeep (calls executeOrder)
        vault.performUpkeep(data);

        // verify owner received tokenB
        assertEq(tokenB.balanceOf(owner), 100 ether);
    }

    function test_checkUpkeep_returns_false_when_price_not_met_or_inactive() public {
        // approve vault
        tokenA.approve(address(vault), 100 ether);

        // create order with high trigger so not met
        uint256 orderId = vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            100 ether,
            250,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            0,
            100
        );

        (bool ok, ) = vault.checkUpkeep(abi.encode(0));
        assertFalse(ok, "checkUpkeep should be false when price not met");

        // now update feed to satisfy trigger
        feed.setAnswer(300);
        (bool ok2, ) = vault.checkUpkeep(abi.encode(0));
        assertTrue(ok2, "checkUpkeep should be true after feed update");

        // cancel the order and ensure checkUpkeep ignores it
        vault.cancelOrder(orderId);
        (bool ok3, ) = vault.checkUpkeep(abi.encode(0));
        // since only order is cancelled, upkeep should be false
        assertFalse(ok3, "checkUpkeep should be false after cancel");
    }

    function test_createOrder_validation_reverts() public {
        tokenA.approve(address(vault), 1_000 ether);

        vm.expectRevert("totalAmount required");
        vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            0,
            1,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            0,
            100
        );

        vm.expectRevert("amountPerSwap > total");
        vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            101 ether,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            0,
            100
        );

        vm.expectRevert("invalid pool fee");
        vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            100 ether,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            42,
            0,
            100
        );

        vm.expectRevert("Limit: cadence must be 0");
        vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            100 ether,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.Limit,
            3000,
            60,
            100
        );

        vm.expectRevert("DCA: cadence too short");
        vault.createOrder(
            address(tokenA), address(tokenB), address(feed),
            100 ether,
            10 ether,
            150,
            PriceVault.TriggerType.Above,
            PriceVault.OrderKind.DCA,
            3000,
            59,
            100
        );
    }

    function test_dca_executes_in_chunks_and_respects_cadence() public {
        uint256 orderId = _createDcaOrder(300 ether, 100 ether, 120);

        vault.executeOrder(orderId);
        PriceVault.Order memory afterFirst = vault.getOrder(orderId);
        assertEq(afterFirst.amountRemaining, 200 ether);
        assertTrue(afterFirst.active);
        uint256 firstNextExecution = uint256(afterFirst.nextExecution);

        vm.expectRevert("DCA: too early");
        vault.executeOrder(orderId);

        vm.warp(firstNextExecution);
        vault.executeOrder(orderId);
        PriceVault.Order memory afterSecond = vault.getOrder(orderId);
        assertEq(afterSecond.amountRemaining, 100 ether);
        assertTrue(afterSecond.active);
        uint256 secondNextExecution = uint256(afterSecond.nextExecution);

        vm.warp(secondNextExecution);
        vault.executeOrder(orderId);
        PriceVault.Order memory finalOrder = vault.getOrder(orderId);
        assertEq(finalOrder.amountRemaining, 0);
        assertFalse(finalOrder.active);
        assertEq(tokenB.balanceOf(owner), 300 ether);
    }

    function test_cancel_dca_returns_unspent_balance() public {
        uint256 orderId = _createDcaOrder(300 ether, 100 ether, 120);

        vault.executeOrder(orderId);
        vault.cancelOrder(orderId);

        assertEq(tokenA.balanceOf(owner), 999_900 ether);
        PriceVault.Order memory o = vault.getOrder(orderId);
        assertFalse(o.active);
        assertEq(o.amountRemaining, 0);
    }

    function test_checkUpkeep_ignores_stale_price_until_refreshed() public {
        _createLimitOrder(150);

        vm.warp(block.timestamp + 3601);
        (bool staleOk, ) = vault.checkUpkeep(abi.encode(0));
        assertFalse(staleOk);

        feed.setAnswer(200);
        (bool refreshedOk, ) = vault.checkUpkeep(abi.encode(0));
        assertTrue(refreshedOk);
    }

    function test_onlyOwner_admin_guards() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not owner");
        vault.setSwapRouter(address(router));

        vault.setStaleThreshold(120);
        assertEq(vault.staleThreshold(), 120);

        vault.setUpkeepScanLimit(32);
        assertEq(vault.upkeepScanLimit(), 32);
    }

    function test_performUpkeep_reverts_for_invalid_order() public {
        vm.expectRevert("not active");
        vault.performUpkeep(abi.encode(uint256(999)));
    }
}
