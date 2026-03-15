// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Chainlink Aggregator interface (minimal)
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

// Minimal Uniswap V3-style router interface (we only use exactInputSingle)
interface IUniswapV3SwapRouter {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract PriceVault {
    enum TriggerType { Above, Below }
    enum OrderKind { Limit, DCA }

    struct Order {
        address owner;
        address sellToken;
        address buyToken;
        address priceFeed;
        uint256 amount;
        uint256 priceTrigger;
        TriggerType triggerType;
        OrderKind kind;
        uint64 cadence;
        uint64 nextExecution;
        uint16 maxSlippageBps;
        bool active;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;

    event OrderCreated(uint256 indexed orderId, address indexed owner);
    event OrderCancelled(uint256 indexed orderId, address indexed owner);
    event OrderExecuted(uint256 indexed orderId, address indexed executor);

    constructor() {}

    // simple swap router address (can be Uniswap-style adapter)
    address public swapRouter;

    function setSwapRouter(address _router) external {
        swapRouter = _router;
    }
    


    function createOrder(
        address sellToken,
        address buyToken,
        address priceFeed,
        uint256 amount,
        uint256 priceTrigger,
        TriggerType triggerType,
        OrderKind kind,
        uint64 cadence,
        uint16 maxSlippageBps
    ) external returns (uint256) {
        require(amount > 0, "amount>0");
        require(sellToken != address(0), "sell token required");

        // pull tokens into contract
        bool ok = IERC20(sellToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");

        uint256 id = nextOrderId++;
        orders[id] = Order({
            owner: msg.sender,
            sellToken: sellToken,
            buyToken: buyToken,
            priceFeed: priceFeed,
            amount: amount,
            priceTrigger: priceTrigger,
            triggerType: triggerType,
            kind: kind,
            cadence: cadence,
            nextExecution: 0,
            maxSlippageBps: maxSlippageBps,
            active: true
        });

        userOrders[msg.sender].push(id);
        emit OrderCreated(id, msg.sender);
        return id;
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.active, "not active");
        require(o.owner == msg.sender, "not owner");

        o.active = false;
        // refund remaining amount
        if (o.amount > 0) {
            IERC20(o.sellToken).transfer(o.owner, o.amount);
            o.amount = 0;
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // Minimal execute path for scaffolding: mark executed and transfer sellToken to executor as a placeholder
    function executeOrder(uint256 orderId) public {
        Order storage o = orders[orderId];
        require(o.active, "not active");
        require(o.amount > 0, "no amount");

        // check price via Chainlink feed if provided
        if (o.priceFeed != address(0)) {
            AggregatorV3Interface feed = AggregatorV3Interface(o.priceFeed);
            (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
            require(updatedAt != 0, "stale feed");
            require(answer > 0, "bad feed");
            uint256 price = uint256(answer);

            if (o.triggerType == TriggerType.Above) {
                require(price >= o.priceTrigger, "price below trigger");
            } else {
                require(price <= o.priceTrigger, "price above trigger");
            }
        }

        // perform swap via Uniswap V3-style router
        require(swapRouter != address(0), "no router");
        // approve router to pull sell token
        IERC20(o.sellToken).approve(swapRouter, o.amount);
        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: o.sellToken,
            tokenOut: o.buyToken,
            fee: 3000,
            recipient: o.owner,
            deadline: block.timestamp + 60,
            amountIn: o.amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = IUniswapV3SwapRouter(swapRouter).exactInputSingle(params);

        // mark inactive and zero out amount
        o.amount = 0;
        o.active = false;

        emit OrderExecuted(orderId, msg.sender);
    }

    // Chainlink Automation / Keeper-compatible hooks (simple implementation)
    // Scans orders up to a small limit and returns the first executable order id in performData.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 limit = nextOrderId;
        if (limit > 128) limit = 128; // gas-safety
        for (uint256 i = 0; i < limit; i++) {
            Order storage o = orders[i];
            if (!o.active) continue;
            if (o.amount == 0) continue;
            if (o.priceFeed == address(0)) continue; // require feed for automation
            AggregatorV3Interface feed = AggregatorV3Interface(o.priceFeed);
            (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
            if (updatedAt == 0 || answer <= 0) continue;
            uint256 price = uint256(answer);
            if (o.triggerType == TriggerType.Above && price >= o.priceTrigger) {
                return (true, abi.encode(i));
            }
            if (o.triggerType == TriggerType.Below && price <= o.priceTrigger) {
                return (true, abi.encode(i));
            }
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external {
        uint256 id = abi.decode(performData, (uint256));
        // call executeOrder which will perform checks and swap
        executeOrder(id);
    }

    // View helpers
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }
}
