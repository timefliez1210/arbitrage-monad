// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";
import {
    FixedPointMathLib
} from "@kuru/contracts/libraries/FixedPointMathLib.sol";

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
/// @dev Uses V3's swap callback pattern for flash-style execution (no own capital needed)
///
/// PRICE CONVENTIONS:
/// - V3 Pool (WMON/gMON): sqrtPriceX96 gives price of token1 (gMON) in terms of token0 (WMON)
///   So V3 price = gMON per WMON
/// - Kuru OB (MON/gMON): bestBidAsk returns price in MON per gMON
///   Bid = price to sell gMON for MON, Ask = price to buy gMON with MON
/// - Since WMON = MON, we need to INVERT V3 price to compare with Kuru
///   V3 inverted = MON per gMON = 1e36 / v3Price
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

    /// @notice Price scale factor (1e18)
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 constant BASE_MULTIPLIER = 1e18;

    /// @notice Min/Max sqrt price for V3
    uint160 public constant MIN_SQRT_RATIO = 4295128739;
    uint160 public constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    address public immutable owner;

    /// @notice Kuru market params (cached at deploy)
    uint32 public immutable pricePrecision;
    uint96 public immutable sizePrecision;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _owner) {
        owner = _owner;

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

    /// @notice Lightweight profit check for off-chain keepers
    /// @dev Uses 20 tick depth for speed. Returns only essential data.
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        (uint160 sqrtPriceX96, , , , , , ) = V3_POOL.slot0();

        // V3 price = gMON per WMON, but Kuru uses MON per gMON
        // Invert: v3PriceInverted = 1e36 / v3Price = MON per gMON
        uint256 v3PriceRaw = _sqrtPriceToPrice(sqrtPriceX96);
        if (v3PriceRaw == 0) return (false, 0);
        uint256 v3Price = (1e36) / v3PriceRaw; // Now in MON/gMON like Kuru

        (uint256 kuruBid, uint256 kuruAsk) = KURU_OB.bestBidAsk();

        // V3 fee 0.3% + Kuru fee 0.02% = ~32 bps
        uint256 fee = (v3Price * 32) / 10000;

        // Forward: V3 price < Kuru bid → Buy gMON on V3 (cheap), sell on Kuru (expensive)
        // When V3 gives more gMON per MON than Kuru bid price
        if (v3Price + fee < kuruBid) {
            uint256 kuruSize = getAggregatedBidSize(20, v3Price + fee);
            if (kuruSize > 0) {
                // Use 95% of spread to better reflect actual execution
                uint256 effectiveSpread = ((kuruBid - v3Price) * 95) / 100;
                // Margin: 20bps price + 25bps size = 45bps
                uint256 executeMargin = (kuruBid * 45) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        1e18;
                    if (expectedProfit > 15e15) {
                        profitable = true;
                    }
                }
            }
        }
        // Reverse: V3 price > Kuru ask → Buy gMON on Kuru (cheap), sell on V3 (expensive)
        else if (v3Price > kuruAsk + fee && kuruAsk > 0) {
            (uint256 kuruSize, ) = getAggregatedAskSize(20, v3Price - fee);
            if (kuruSize > 0) {
                // Use 95% of spread to better reflect actual execution
                uint256 effectiveSpread = ((v3Price - kuruAsk) * 95) / 100;
                // Margin: 7bps price + 20bps size = 27bps
                uint256 executeMargin = (kuruAsk * 27) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        v3Price;
                    if (expectedProfit > 0.75 ether) {
                        profitable = true;
                    }
                }
            }
        }
    }

    /// @notice Execute arbitrage
    /// @return success True if arbitrage was profitable
    function execute() external returns (bool success) {
        (uint160 sqrtPriceX96, , , , , , ) = V3_POOL.slot0();

        // V3 price inverted to match Kuru's MON/gMON convention
        uint256 v3PriceRaw = _sqrtPriceToPrice(sqrtPriceX96);
        if (v3PriceRaw == 0) return false;
        uint256 v3Price = (1e36) / v3PriceRaw;

        (uint256 bestBid, uint256 bestAsk) = KURU_OB.bestBidAsk();

        // V3 fee 0.3% + Kuru fee 0.02% = ~32 bps
        uint256 fee = (v3Price * 32) / 10000;

        bool zeroForOne;
        uint256 kuruVolWei;
        uint160 sqrtLimit;
        uint256 maxQuoteSpend;

        if (v3Price + fee < bestBid) {
            // Forward: Buy gMON on V3 (low), sell on Kuru (high)
            // V3: sell WMON (token0) for gMON (token1) → zeroForOne = true
            zeroForOne = true;

            kuruVolWei = getAggregatedBidSize(50, v3Price + fee);

            // Calculate sqrtPriceLimit
            // We're buying gMON, which decreases the V3 price (gMON/WMON)
            // Stop if inverted price (MON/gMON) >= bestBid - margin
            uint256 safeBid = (bestBid * 9980) / 10000;
            // Invert back: v3PriceRaw limit = 1e36 / safeBid
            uint256 v3PriceLimit = (1e36) / safeBid;
            sqrtLimit = _priceToSqrtPrice(v3PriceLimit);

            // For zeroForOne=true, sqrtLimit must be < current
            if (sqrtLimit >= sqrtPriceX96) return false;
        } else if (v3Price > bestAsk + fee && bestAsk > 0) {
            // Reverse: Buy gMON on Kuru (low), sell on V3 (high)
            // V3: sell gMON (token1) for WMON (token0) → zeroForOne = false
            zeroForOne = false;

            (kuruVolWei, maxQuoteSpend) = getAggregatedAskSize(
                50,
                v3Price - fee
            );
            maxQuoteSpend = (maxQuoteSpend * 9980) / 10000; // 0.2% buffer

            // Calculate sqrtPriceLimit
            // We're selling gMON, which increases the V3 price (gMON/WMON)
            // Stop if inverted price (MON/gMON) <= bestAsk + margin
            uint256 safeAsk = (bestAsk * 10007) / 10000;
            uint256 v3PriceLimit = (1e36) / safeAsk;
            sqrtLimit = _priceToSqrtPrice(v3PriceLimit);

            // For zeroForOne=false, sqrtLimit must be > current
            if (sqrtLimit <= sqrtPriceX96) return false;
        } else {
            return false;
        }

        if (kuruVolWei == 0) return false;

        // Execute via V3 swap callback
        bytes memory data = abi.encode(zeroForOne, kuruVolWei, maxQuoteSpend);

        if (zeroForOne) {
            // Forward: exactOutput gMON (negative = exact output)
            int256 amountSpecified = -int256(kuruVolWei);
            V3_POOL.swap(address(this), true, amountSpecified, sqrtLimit, data);
        } else {
            // Reverse: exactOutput WMON (we want WMON to unwrap to MON for Kuru)
            int256 amountSpecified = -int256(maxQuoteSpend);
            V3_POOL.swap(
                address(this),
                false,
                amountSpecified,
                sqrtLimit,
                data
            );
        }

        success = true;
        _sweepProfits();
    }

    /// @notice V3 swap callback - THIS IS WHERE THE ARB HAPPENS
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(msg.sender == address(V3_POOL), "Invalid callback");

        (bool isForward, , ) = abi.decode(data, (bool, uint256, uint256));

        if (isForward) {
            // FORWARD: We received gMON (amount1Delta < 0), must pay WMON (amount0Delta > 0)
            uint256 gmonReceived = uint256(-amount1Delta);
            uint256 wmonOwed = uint256(amount0Delta);

            // 1. Sell gMON on Kuru for MON
            uint96 sellSize = uint96((gmonReceived * sizePrecision) / 1e18);
            if (sellSize > 0) {
                GMON.approve(address(KURU_OB), gmonReceived);
                KURU_OB.placeAndExecuteMarketSell(sellSize, 0, false, false);
            }

            // 2. Wrap MON to WMON
            uint256 monBalance = address(this).balance;
            require(monBalance > 0, "No MON from Kuru");
            WMON.deposit{value: monBalance}();

            // 3. Pay V3 the WMON we owe
            require(
                WMON.balanceOf(address(this)) >= wmonOwed,
                "Insufficient WMON"
            );
            WMON.transfer(msg.sender, wmonOwed);
        } else {
            // REVERSE: We received WMON (amount0Delta < 0), must pay gMON (amount1Delta > 0)
            uint256 wmonReceived = uint256(-amount0Delta);
            uint256 gmonOwed = uint256(amount1Delta);

            // 1. Unwrap WMON to MON
            WMON.withdraw(wmonReceived);

            // 2. Buy gMON on Kuru with MON
            uint256 monBalance = address(this).balance;
            uint96 quoteInput = uint96((monBalance * pricePrecision) / 1e18);
            KURU_OB.placeAndExecuteMarketBuy{value: monBalance}(
                quoteInput,
                0,
                false,
                false
            );

            // 3. Pay V3 the gMON we owe
            uint256 gmonBalance = GMON.balanceOf(address(this));
            require(gmonBalance >= gmonOwed, "Insufficient gMON");
            GMON.transfer(msg.sender, gmonOwed);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Convert sqrtPriceX96 to price (gMON per WMON, 1e18 scale)
    function _sqrtPriceToPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        return (sqrtPrice * sqrtPrice * PRICE_SCALE) >> 192;
    }

    /// @notice Convert price (1e18) to sqrtPriceX96
    function _priceToSqrtPrice(
        uint256 price1e18
    ) internal pure returns (uint160) {
        uint256 root = FixedPointMathLib.sqrt(price1e18);
        return uint160((root << 96) / 1e9);
    }

    function _sweepProfits() internal {
        uint256 wmonBalance = WMON.balanceOf(address(this));
        if (wmonBalance > 0) WMON.transfer(owner, wmonBalance);

        uint256 monBalance = address(this).balance;
        if (monBalance > 0) payable(owner).transfer(monBalance);

        uint256 gmonBalance = GMON.balanceOf(address(this));
        if (gmonBalance > 0) GMON.transfer(owner, gmonBalance);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORDERBOOK HELPERS (matches ArbitrageAUSD pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    function getAggregatedBidSize(
        uint32 ticksBid,
        uint256 minPrice
    ) public view returns (uint256 totalSizeWei) {
        uint256 totalSizeRaw;
        // Convert 1e18 price to raw pricePrecision
        uint256 minPriceRaw = (minPrice * pricePrecision) / 1e18;

        bytes memory data = KURU_OB.getL2Book(ticksBid, 0);

        assembly {
            let ptr := add(data, 64)
            for {
                let i := 0
            } lt(i, ticksBid) {
                i := add(i, 1)
            } {
                let price := mload(ptr)
                if iszero(price) {
                    break
                }
                if lt(price, minPriceRaw) {
                    break
                }

                let size := mload(add(ptr, 32))
                if gt(size, 1000000000000000000000000000000) {
                    size := shr(160, size)
                }
                totalSizeRaw := add(totalSizeRaw, size)
                ptr := add(ptr, 64)
            }
        }

        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / sizePrecision;
    }

    function getAggregatedAskSize(
        uint32 ticksAsk,
        uint256 maxPrice
    ) public view returns (uint256 totalSizeWei, uint256 totalCostMON) {
        uint256 totalSizeRaw;
        // Convert 1e18 price to raw pricePrecision
        uint256 maxPriceRaw = (maxPrice * pricePrecision) / 1e18;

        bytes memory data = KURU_OB.getL2Book(0, ticksAsk);

        assembly {
            let ptr := add(data, 96) // Skip bid delimiter
            for {
                let i := 0
            } lt(i, ticksAsk) {
                i := add(i, 1)
            } {
                let price := mload(ptr)
                if iszero(price) {
                    break
                }
                if gt(price, maxPriceRaw) {
                    break
                }

                let size := mload(add(ptr, 32))
                if gt(size, 1000000000000000000000000000000) {
                    size := shr(160, size)
                }
                totalSizeRaw := add(totalSizeRaw, size)

                // Cost in MON (quote) = size * price / pricePrecision
                let costRaw := mul(size, price)
                let cost := div(costRaw, 1000000) // pricePrecision = 1e6 for gMON
                totalCostMON := add(totalCostMON, cost)

                ptr := add(ptr, 64)
            }
        }

        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / sizePrecision;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");
        uint256 wmonBalance = WMON.balanceOf(address(this));
        if (wmonBalance > 0) WMON.transfer(owner, wmonBalance);
        uint256 gmonBalance = GMON.balanceOf(address(this));
        if (gmonBalance > 0) GMON.transfer(owner, gmonBalance);
        uint256 monBalance = address(this).balance;
        if (monBalance > 0) payable(owner).transfer(monBalance);
    }

    receive() external payable {}
}
