// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title PriceVault v2
 * @notice Limit and DCA orders executed via Chainlink price feeds + Uniswap V3.
 *         Compatible with Chainlink Automation (checkUpkeep / performUpkeep).
 *
 * Improvements over v1:
 *  - Ownable: admin functions gated behind onlyOwner
 *  - ReentrancyGuard: protects executeOrder / cancelOrder
 *  - Configurable fee tier per order (no hardcoded 3000)
 *  - amountOutMinimum computed from maxSlippageBps (slippage actually enforced)
 *  - Stale feed guard: rejects data older than STALE_THRESHOLD
 *  - DCA: cadence / nextExecution logic fully implemented
 *  - DCA: partial fills — each execution spends `amountPerSwap`, not full balance
 *  - cancelOrder: returns full remaining balance including unspent DCA funds
 *  - checkUpkeep: configurable scan window, not hardcoded 128
 *  - Price feed decimals normalised (handles non-8-decimal feeds correctly)
 *  - Events include key fields for easier off-chain indexing
 *  - Explicit safe-transfer helpers (handles non-standard ERC20s like USDT)
 */
contract PriceVault {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    enum TriggerType { Above, Below }
    enum OrderKind  { Limit, DCA }

    struct Order {
        address owner;
        address sellToken;
        address buyToken;
        address priceFeed;
        uint256 totalAmount;      // total deposited (Limit: full swap; DCA: total budget)
        uint256 amountPerSwap;    // Limit: same as totalAmount; DCA: chunk per execution
        uint256 amountRemaining;  // decremented on each DCA fill; zeroed on Limit fill
        uint256 priceTrigger;     // in feed's native decimals (usually 8)
        TriggerType triggerType;
        OrderKind kind;
        uint24  poolFee;          // Uniswap V3 fee tier: 100 / 500 / 3000 / 10000
        uint64  cadence;          // DCA interval in seconds (0 for Limit orders)
        uint64  nextExecution;    // unix timestamp of earliest next DCA execution
        uint16  maxSlippageBps;   // e.g. 50 = 0.5%
        bool    active;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;
    address public swapRouter;

    /// @notice How old a Chainlink answer may be before we reject it (seconds)
    uint256 public staleThreshold = 3600; // 1 hour default

    /// @notice Max orders scanned per checkUpkeep call
    uint256 public upkeepScanLimit = 256;

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) private _userOrders;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        address sellToken,
        address buyToken,
        uint256 totalAmount,
        uint256 priceTrigger,
        TriggerType triggerType,
        OrderKind kind
    );
    event OrderExecuted(
        uint256 indexed orderId,
        address indexed executor,
        uint256 amountIn,
        uint256 amountOut,
        uint256 price
    );
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed owner,
        uint256 refundAmount
    );
    event RouterUpdated(address indexed newRouter);
    event StaleThresholdUpdated(uint256 newThreshold);
    event UpkeepScanLimitUpdated(uint256 newLimit);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _router) {
        require(_router != address(0), "router required");
        owner = msg.sender;
        swapRouter = _router;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setSwapRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero address");
        swapRouter = _router;
        emit RouterUpdated(_router);
    }

    function setStaleThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold >= 60, "threshold too low");
        staleThreshold = _threshold;
        emit StaleThresholdUpdated(_threshold);
    }

    function setUpkeepScanLimit(uint256 _limit) external onlyOwner {
        require(_limit > 0 && _limit <= 512, "bad limit");
        upkeepScanLimit = _limit;
        emit UpkeepScanLimitUpdated(_limit);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        owner = newOwner;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order creation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param sellToken       Token deposited and sold
     * @param buyToken        Token received
     * @param priceFeed       Chainlink aggregator (address(0) skips price check)
     * @param totalAmount     Total sellToken amount deposited
     * @param amountPerSwap   For DCA: amount per execution. For Limit: must equal totalAmount.
     * @param priceTrigger    Price threshold in feed decimals (usually 1e8)
     * @param triggerType     Above or Below
     * @param kind            Limit or DCA
     * @param poolFee         Uniswap V3 pool fee: 100 / 500 / 3000 / 10000
     * @param cadence         DCA: seconds between executions. Limit: set 0.
     * @param maxSlippageBps  Max acceptable slippage in basis points (e.g. 50 = 0.5%)
     */
    function createOrder(
        address sellToken,
        address buyToken,
        address priceFeed,
        uint256 totalAmount,
        uint256 amountPerSwap,
        uint256 priceTrigger,
        TriggerType triggerType,
        OrderKind kind,
        uint24  poolFee,
        uint64  cadence,
        uint16  maxSlippageBps
    ) external nonReentrant returns (uint256 orderId) {
        require(totalAmount > 0,           "totalAmount required");
        require(amountPerSwap > 0,         "amountPerSwap required");
        require(amountPerSwap <= totalAmount, "amountPerSwap > total");
        require(sellToken != address(0),   "sellToken required");
        require(buyToken  != address(0),   "buyToken required");
        require(buyToken  != sellToken,    "tokens must differ");
        require(maxSlippageBps <= 2000,    "slippage > 20%");
        require(
            poolFee == 100 || poolFee == 500 || poolFee == 3000 || poolFee == 10000,
            "invalid pool fee"
        );

        if (kind == OrderKind.Limit) {
            require(cadence == 0, "Limit: cadence must be 0");
            require(amountPerSwap == totalAmount, "Limit: amountPerSwap must equal total");
        } else {
            require(cadence >= 60, "DCA: cadence too short");
        }

        _safeTransferFrom(sellToken, msg.sender, address(this), totalAmount);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner:           msg.sender,
            sellToken:       sellToken,
            buyToken:        buyToken,
            priceFeed:       priceFeed,
            totalAmount:     totalAmount,
            amountPerSwap:   amountPerSwap,
            amountRemaining: totalAmount,
            priceTrigger:    priceTrigger,
            triggerType:     triggerType,
            kind:            kind,
            poolFee:         poolFee,
            cadence:         cadence,
            nextExecution:   0,
            maxSlippageBps:  maxSlippageBps,
            active:          true
        });

        _userOrders[msg.sender].push(orderId);

        emit OrderCreated(
            orderId, msg.sender, sellToken, buyToken,
            totalAmount, priceTrigger, triggerType, kind
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cancel
    // ─────────────────────────────────────────────────────────────────────────

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.active,              "not active");
        require(o.owner == msg.sender, "not owner");

        uint256 refund = o.amountRemaining;
        o.active          = false;
        o.amountRemaining = 0;

        if (refund > 0) {
            _safeTransfer(o.sellToken, o.owner, refund);
        }

        emit OrderCancelled(orderId, msg.sender, refund);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Execute
    // ─────────────────────────────────────────────────────────────────────────

    function executeOrder(uint256 orderId) public nonReentrant {
        Order storage o = orders[orderId];
        require(o.active,           "not active");
        require(o.amountRemaining > 0, "no funds remaining");

        // ── DCA timing check ─────────────────────────────────────────────────
        if (o.kind == OrderKind.DCA) {
            require(block.timestamp >= o.nextExecution, "DCA: too early");
        }

        // ── Price check ──────────────────────────────────────────────────────
        uint256 currentPrice = 0;
        if (o.priceFeed != address(0)) {
            currentPrice = _getPrice(o.priceFeed);
            if (o.triggerType == TriggerType.Above) {
                require(currentPrice >= o.priceTrigger, "price below trigger");
            } else {
                require(currentPrice <= o.priceTrigger, "price above trigger");
            }
        }

        // ── Determine swap amount ─────────────────────────────────────────────
        uint256 swapAmount = o.kind == OrderKind.DCA
            ? _min(o.amountPerSwap, o.amountRemaining)
            : o.amountRemaining;

        // ── Compute amountOutMinimum from slippage ────────────────────────────
        // We estimate expected output using price feed if available.
        // Falls back to 1 if no feed (still prevents zero-output sandwich).
        uint256 amountOutMin = _computeMinOut(
            o.sellToken,
            o.buyToken,
            swapAmount,
            o.priceFeed,
            currentPrice,
            o.maxSlippageBps
        );

        // ── Update state BEFORE external calls (checks-effects-interactions) ──
        o.amountRemaining -= swapAmount;

        bool isDone = (o.kind == OrderKind.Limit) || (o.amountRemaining == 0);
        if (isDone) {
            o.active = false;
        } else {
            o.nextExecution = uint64(block.timestamp) + o.cadence;
        }

        // ── Swap ──────────────────────────────────────────────────────────────
        IERC20(o.sellToken).approve(swapRouter, swapAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           o.sellToken,
            tokenOut:          o.buyToken,
            fee:               o.poolFee,
            recipient:         o.owner,
            deadline:          block.timestamp + 120,
            amountIn:          swapAmount,
            amountOutMinimum:  amountOutMin,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        // Reset approval to 0 (good practice, required by some tokens like USDT)
        IERC20(o.sellToken).approve(swapRouter, 0);

        emit OrderExecuted(orderId, msg.sender, swapAmount, amountOut, currentPrice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Chainlink Automation
    // ─────────────────────────────────────────────────────────────────────────

    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 limit = nextOrderId < upkeepScanLimit ? nextOrderId : upkeepScanLimit;

        for (uint256 i = 0; i < limit; i++) {
            Order storage o = orders[i];
            if (!o.active)              continue;
            if (o.amountRemaining == 0) continue;
            if (o.priceFeed == address(0)) continue; // require feed for automation

            // DCA timing
            if (o.kind == OrderKind.DCA && block.timestamp < o.nextExecution) continue;

            // Price check (view — no state change)
            (bool ok, uint256 price) = _tryGetPrice(o.priceFeed);
            if (!ok) continue;

            bool triggered = (o.triggerType == TriggerType.Above)
                ? price >= o.priceTrigger
                : price <= o.priceTrigger;

            if (triggered) {
                return (true, abi.encode(i));
            }
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external {
        uint256 id = abi.decode(performData, (uint256));
        executeOrder(id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────────

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Returns all active order IDs for a user
    function getActiveUserOrders(address user) external view returns (uint256[] memory) {
        uint256[] storage all = _userOrders[user];
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            if (orders[all[i]].active) count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (orders[all[i]].active) result[j++] = all[i];
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reads price from Chainlink feed. Reverts on stale/bad data.
    function _getPrice(address feed) internal view returns (uint256 price) {
        AggregatorV3Interface agg = AggregatorV3Interface(feed);
        (, int256 answer, , uint256 updatedAt, ) = agg.latestRoundData();
        require(answer > 0, "bad feed answer");
        require(updatedAt != 0, "round not complete");
        require(block.timestamp - updatedAt <= staleThreshold, "stale feed");
        return uint256(answer);
    }

    /// @dev Non-reverting price read for checkUpkeep (view context).
    function _tryGetPrice(address feed)
        internal
        view
        returns (bool ok, uint256 price)
    {
        try AggregatorV3Interface(feed).latestRoundData()
            returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            if (
                answer > 0 &&
                updatedAt != 0 &&
                block.timestamp - updatedAt <= staleThreshold
            ) {
                return (true, uint256(answer));
            }
        } catch {}
        return (false, 0);
    }

    /**
     * @dev Estimate amountOutMinimum using price feed.
     *      Formula: amountIn * (price / 10^feedDec) * (10^buyDec / 10^sellDec) * (1 - slip)
     *      Falls back to 1 if feed unavailable (prevents zero-output swaps).
     */
    function _computeMinOut(
        address sellToken,
        address buyToken,
        uint256 amountIn,
        address feed,
        uint256 currentPrice,
        uint16  slippageBps
    ) internal view returns (uint256) {
        if (feed == address(0) || currentPrice == 0) return 1;

        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        uint8 sellDecimals = IERC20(sellToken).decimals();
        uint8 buyDecimals  = IERC20(buyToken).decimals();

        // expected output in buy-token units (no slippage yet)
        // = amountIn * currentPrice * 10^buyDecimals / (10^feedDecimals * 10^sellDecimals)
        uint256 expectedOut = (amountIn * currentPrice * (10 ** uint256(buyDecimals)))
            / ((10 ** uint256(feedDecimals)) * (10 ** uint256(sellDecimals)));

        if (expectedOut == 0) return 1;

        // apply slippage: expectedOut * (10000 - slippageBps) / 10000
        return (expectedOut * (10000 - uint256(slippageBps))) / 10000;
    }

    /// @dev Safe transferFrom that works with non-standard tokens (e.g. USDT on mainnet).
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    /// @dev Safe transfer that works with non-standard tokens.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
