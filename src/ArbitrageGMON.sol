// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";

/// @title Uniswap V3 Pool Interface (minimal)
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title WMON Interface (Wrapped MON)
interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title ArbitrageGMON - MON/gMON Arbitrage using Uniswap V3 + Kuru
/// @notice Arbitrages price discrepancies between V3 pool (WMON/gMON) and Kuru orderbook (MON/gMON)
/// @dev Uses V3's swap callback pattern for flash-style execution
contract ArbitrageGMON {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Wrapped MON token (V3 uses WMON, not native MON)
    IWMON public constant WMON =
        IWMON(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);

    /// @notice gMON staked token
    IERC20 public constant GMON =
        IERC20(0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081);

    /// @notice Uniswap V3 pool for WMON/gMON
    IUniswapV3Pool public constant V3_POOL =
        IUniswapV3Pool(0xb80d7a8F5331A907E34CD73f575c784B43E5acb5);

    /// @notice Kuru orderbook for MON/gMON
    IOrderBook public constant KURU_OB =
        IOrderBook(0x1CA0F16a316c3EE0Ff3CEC5382cAaD5648Ea512D);

    /// @notice Price scale factor for Kuru (1e18)
    uint256 public constant PRICE_SCALE = 1e18;

    /// @notice Min sqrt price for V3 (prevents revert on extreme swaps)
    uint160 public constant MIN_SQRT_RATIO = 4295128739;

    /// @notice Max sqrt price for V3
    uint160 public constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    address public immutable owner;
    address public immutable profitRecipient;

    /// @notice Kuru market params (cached at deploy)
    uint32 public immutable pricePrecision;
    uint96 public immutable sizePrecision;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _profitRecipient) {
        owner = msg.sender;
        profitRecipient = _profitRecipient;

        // Cache Kuru market params
        (uint32 pp, uint96 sp, , , , , , , , , ) = KURU_OB.getMarketParams();
        pricePrecision = pp;
        sizePrecision = sp;

        // Approve gMON for Kuru
        GMON.approve(address(KURU_OB), type(uint256).max);

        // Approve WMON for V3 pool
        WMON.approve(address(V3_POOL), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if profitable arbitrage exists
    /// @return profitable True if profitable opportunity exists
    /// @return expectedProfit Estimated profit in MON (18 decimals)
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        // Get V3 price (sqrtPriceX96)
        (uint160 sqrtPriceX96, , , , , , ) = V3_POOL.slot0();

        // Convert to 1e18 price (gMON per WMON)
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        uint256 v3Price = _sqrtPriceToPrice(sqrtPriceX96);

        // Get Kuru best bid/ask (already in 1e18 scale!)
        // Bid = price to sell gMON for MON
        // Ask = price to buy gMON with MON
        (uint256 kuruBid, uint256 kuruAsk) = KURU_OB.bestBidAsk();

        // Check for arbitrage:
        // Forward: V3 price < Kuru bid → Buy gMON on V3, sell on Kuru
        // Reverse: V3 price > Kuru ask → Buy gMON on Kuru, sell on V3

        if (v3Price > 0 && kuruBid > v3Price) {
            // Forward arb: V3 → Kuru
            expectedProfit = ((kuruBid - v3Price) * 1e18) / v3Price; // % profit scaled
            profitable = expectedProfit > 5e15; // > 0.5% threshold
        } else if (v3Price > 0 && v3Price > kuruAsk && kuruAsk > 0) {
            // Reverse arb: Kuru → V3
            expectedProfit = ((v3Price - kuruAsk) * 1e18) / kuruAsk;
            profitable = expectedProfit > 5e15;
        }
    }

    /// @notice Execute arbitrage
    /// @return success True if arbitrage was profitable
    function execute() external returns (bool success) {
        require(msg.sender == owner, "Not owner");

        // Get prices
        (uint160 sqrtPriceX96, , , , , , ) = V3_POOL.slot0();
        uint256 v3Price = _sqrtPriceToPrice(sqrtPriceX96);
        (uint256 bestBid, uint256 bestAsk) = KURU_OB.bestBidAsk();

        // Kuru prices are already in 1e18 scale (MON per gMON)

        if (bestBid > v3Price) {
            // Forward: Buy gMON on V3, sell on Kuru for MON
            success = _executeForward(sqrtPriceX96);
        } else if (v3Price > bestAsk && bestAsk > 0) {
            // Reverse: Buy gMON on Kuru with MON, sell on V3 for WMON
            success = _executeReverse(sqrtPriceX96);
        }

        // Sweep profits
        _sweepProfits();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Forward arb: V3 flash → Kuru
    /// @dev Flash borrow gMON from V3, sell on Kuru for MON, wrap to WMON, pay V3
    function _executeForward(uint160) internal returns (bool) {
        // Determine trade size - use a reasonable amount based on liquidity
        // For flash, we request gMON output, pay WMON in callback
        // amountSpecified < 0 means "give me exactly X output tokens"
        int256 amountSpecified = -1 ether; // Request 1 gMON (adjust based on liquidity)

        V3_POOL.swap(
            address(this),
            true, // zeroForOne: we're buying gMON with WMON
            amountSpecified, // negative = exact output
            MIN_SQRT_RATIO + 1,
            abi.encode(true, uint256(0)) // Forward flag, no extra data
        );

        return true;
    }

    /// @notice Reverse arb: Kuru flash → V3
    /// @dev Flash borrow WMON from V3, unwrap to MON, buy gMON on Kuru, pay V3 with gMON
    function _executeReverse(uint160) internal returns (bool) {
        // Request WMON output, pay gMON in callback
        int256 amountSpecified = -1 ether; // Request 1 WMON

        V3_POOL.swap(
            address(this),
            false, // zeroForOne=false: we're buying WMON with gMON
            amountSpecified,
            MAX_SQRT_RATIO - 1,
            abi.encode(false, uint256(0)) // Reverse flag
        );

        return true;
    }

    /// @notice V3 swap callback - THIS IS WHERE THE ARB HAPPENS
    /// @dev V3 has already given us the output tokens, now we do the arb and pay back
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(msg.sender == address(V3_POOL), "Invalid callback");

        (bool isForward, ) = abi.decode(data, (bool, uint256));

        if (isForward) {
            // FORWARD: We received gMON (amount1Delta < 0), must pay WMON (amount0Delta > 0)
            uint256 gmonReceived = uint256(-amount1Delta);
            uint256 wmonOwed = uint256(amount0Delta);

            // 1. Sell gMON on Kuru for MON
            uint96 sellSize = uint96(
                (gmonReceived / sizePrecision) * sizePrecision
            );
            if (sellSize > 0) {
                KURU_OB.placeAndExecuteMarketSell(sellSize, 0, false, false);
            }

            // 2. We now have MON - wrap to WMON
            uint256 monBalance = address(this).balance;
            if (monBalance > 0) {
                WMON.deposit{value: monBalance}();
            }

            // 3. Pay V3 the WMON we owe
            WMON.transfer(msg.sender, wmonOwed);

            // Profit = WMON balance - wmonOwed (what we had before paying)
            // Any excess WMON is profit!
        } else {
            // REVERSE: We received WMON (amount0Delta < 0), must pay gMON (amount1Delta > 0)
            uint256 wmonReceived = uint256(-amount0Delta);
            uint256 gmonOwed = uint256(amount1Delta);

            // 1. Unwrap WMON to MON
            WMON.withdraw(wmonReceived);

            // 2. Buy gMON on Kuru with MON
            uint256 monBalance = address(this).balance;
            KURU_OB.placeAndExecuteMarketBuy{value: monBalance}(
                uint96(monBalance),
                0,
                false,
                false
            );

            // 3. Pay V3 the gMON we owe
            GMON.transfer(msg.sender, gmonOwed);

            // Profit = gMON balance - gmonOwed (any excess gMON is profit!)
        }
    }

    /// @notice Convert sqrtPriceX96 to 1e18 price
    function _sqrtPriceToPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        // price = (sqrtPriceX96 / 2^96)^2 * 1e18
        // = sqrtPriceX96^2 * 1e18 / 2^192
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        return (sqrtPrice * sqrtPrice * PRICE_SCALE) >> 192;
    }

    /// @notice Sweep profits to recipient (keeps original currency)
    function _sweepProfits() internal {
        // Sweep WMON profits (keep 0.1 WMON for future trades)
        uint256 wmonBalance = WMON.balanceOf(address(this));
        if (wmonBalance > 0.1 ether) {
            WMON.transfer(profitRecipient, wmonBalance - 0.1 ether);
        }

        // Sweep MON profits (keep 1 MON for gas)
        uint256 monBalance = address(this).balance;
        if (monBalance > 1 ether) {
            payable(profitRecipient).transfer(monBalance - 1 ether);
        }

        // Sweep gMON profits (keep 0.1 gMON for future trades)
        uint256 gmonBalance = GMON.balanceOf(address(this));
        if (gmonBalance > 0.1 ether) {
            GMON.transfer(profitRecipient, gmonBalance - 0.1 ether);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emergency withdraw
    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");

        uint256 wmonBalance = WMON.balanceOf(address(this));
        if (wmonBalance > 0) WMON.transfer(owner, wmonBalance);

        uint256 gmonBalance = GMON.balanceOf(address(this));
        if (gmonBalance > 0) GMON.transfer(owner, gmonBalance);

        uint256 monBalance = address(this).balance;
        if (monBalance > 0) payable(owner).transfer(monBalance);
    }

    /// @notice Receive native MON
    receive() external payable {}
}
