//SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";
import {
    FixedPointMathLib
} from "@kuru/contracts/libraries/FixedPointMathLib.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BitMath} from "v4-core/libraries/BitMath.sol";

import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";

contract ArbitrageUSDC is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    struct TickLiquidity {
        int24 tick;
        uint128 liquidityGross;
        int128 liquidityNet;
    }

    error USDC_BALANCE_NOT_ENOUGH(uint256, uint256, uint256, uint96);
    error SWAP_FAILED(bytes reason);

    //// GENERICS
    //// USDC
    IERC20 public immutable USDC;
    address public immutable USDC_ADDRESS;
    Currency public immutable USDC_CURRENCY;
    address public immutable owner;

    //// MON (Held address 0 in Uniswap and Kuru)
    Currency constant MON_CURRENCY = Currency.wrap(address(0));

    IPoolManager public immutable PM;
    IOrderBook public immutable OB_USDC;

    uint256 public immutable PRICE_PRECISION;
    uint256 public immutable SIZE_PRECISION;
    uint256 constant QUOTE_MULTIPLIER = 1e6;
    uint256 constant BASE_MULTIPLIER = 1e18;

    uint256 public immutable BASE_DECIMALS;
    uint256 public immutable QUOTE_DECIMALS;
    uint256 public immutable PRICE_SCALE_FACTOR;
    uint256 public immutable SQRT_PRICE_SCALE;

    constructor(
        address _pm,
        address _orderBook,
        address _usdc,
        address _owner
    ) {
        PM = IPoolManager(_pm);
        OB_USDC = IOrderBook(_orderBook);
        USDC = IERC20(_usdc);
        USDC_ADDRESS = _usdc;
        USDC_CURRENCY = Currency.wrap(_usdc);
        owner = _owner;

        // Fetch Kuru Params
        (uint32 pp, uint96 sp, , , , , , , , , ) = OB_USDC.getMarketParams();
        PRICE_PRECISION = uint256(pp);
        SIZE_PRECISION = uint256(sp);

        // Decimals
        // Base is MON (0). 18.
        BASE_DECIMALS = 18;
        // Quote is USDC.
        QUOTE_DECIMALS = IERC20Metadata(address(USDC)).decimals();

        // k = 18 + Bd - Qd
        uint256 k = 18 + BASE_DECIMALS - QUOTE_DECIMALS;
        PRICE_SCALE_FACTOR = 10 ** k;
        SQRT_PRICE_SCALE = FixedPointMathLib.sqrt(PRICE_SCALE_FACTOR);
    }

    receive() external payable {}

    function getPoolKey(
        Currency currency
    ) public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON_CURRENCY,
                currency1: currency,
                fee: 500,
                // MON/USDC TickSpacing is 10
                tickSpacing: 10,
                hooks: IHooks(address(0))
            });
    }

    function getUniswapPrice(
        Currency currency
    ) internal view returns (uint256) {
        PoolKey memory key = getPoolKey(currency);
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);

        // Calculate Raw Price Ratio
        uint256 priceRaw = FullMath.mulDiv(
            uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
            PRICE_SCALE_FACTOR,
            1 << 192
        );

        return priceRaw;
    }

    function getKuruPrices()
        internal
        view
        returns (uint256 bestBid, uint256 bestAsk)
    {
        (bestBid, bestAsk) = OB_USDC.bestBidAsk();
    }

    // ============ KEEPER PROFIT (OPTIMIZED) ============

    /// @notice Lightweight profit check for off-chain keepers
    /// @dev Uses 10 tick depth (vs 50) for speed. Returns only essential data.
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        uint256 price1e18 = getUniswapPrice(USDC_CURRENCY);
        (uint256 bestBid, uint256 bestAsk) = OB_USDC.bestBidAsk();
        uint256 fee = (price1e18 * 7) / 10000;

        // Forward check: Uni price < Kuru bid
        if (price1e18 < bestBid && bestBid > price1e18 + fee) {
            uint256 kuruSize = getAggregatedBidSize(10, price1e18 + fee); // 10 ticks only!
            if (kuruSize > 200e18) {
                expectedProfit =
                    ((bestBid - (price1e18 + fee)) * kuruSize) /
                    1e18;
                if (expectedProfit > 3e16) {
                    profitable = true;
                }
            }
        }
        // Reverse check: Uni price > Kuru ask
        else if (
            price1e18 > bestAsk && bestAsk > 0 && bestAsk < price1e18 - fee
        ) {
            (uint256 kuruSize, ) = getAggregatedAskSize(10, price1e18 - fee); // 10 ticks only!
            if (kuruSize > 200e18) {
                expectedProfit =
                    ((price1e18 - fee - bestAsk) * kuruSize) /
                    price1e18;
                if (expectedProfit > 1 ether) {
                    profitable = true;
                }
            }
        }
    }

    function calculateProfit()
        public
        view
        returns (
            bool profitable,
            bool zeroForOne,
            bytes memory data,
            uint256 price1e18,
            uint256 bestBid,
            uint256 bestAsk,
            uint256 expectedProfit
        )
    {
        // 1. Get Uniswap Market Price
        price1e18 = getUniswapPrice(USDC_CURRENCY);

        // 2. Get Current OrderBook State
        (bestBid, bestAsk) = OB_USDC.bestBidAsk();

        // first comparison is to see if we can make a profit
        uint32 ticksToQueuery = 50;
        if (price1e18 < bestBid) {
            // If true, we need to know how much we can trade:
            // 1. queuery orderbook for available liquidity

            // Sum up the orders in the range where price1e18 is less than bestBid
            // This is a "dangerous assumption": We assume by default bigger liquidity in uniswap than kuru at any given time
            // So basically we accept some reverts if uniswaps liquidity is lower than kuru
            // Fee Calculation:
            // Uniswap Fee Tier 500 = 0.05% = 5 bps
            // Kuru Taker Fee = 0.02% = 2 bps
            // Total = 7 bps
            uint256 fee = (price1e18 * 7) / 10000;
            uint256 minPrice = price1e18 + fee;

            uint256 bestBidSizeKuru = getAggregatedBidSize(
                ticksToQueuery,
                minPrice
            );

            if (bestBidSizeKuru < 200e18) {
                return (
                    false,
                    false,
                    data,
                    price1e18,
                    bestBid,
                    bestAsk,
                    expectedProfit
                );
            }

            uint256 amountInWei = bestBidSizeKuru;

            // Truncate to Kuru Precision (Scalar = 1e7)
            // BASE(18) / SIZE(11) = 1e7
            {
                uint256 scalar = BASE_MULTIPLIER / SIZE_PRECISION;
                amountInWei = (amountInWei / scalar) * scalar;

                // SAFETY: Scale down by 0.7% to account for Kuru Fees (deducted from output) and rounding.
                amountInWei = (amountInWei * 9930) / 10000;
            }
            // ------------------------------------------------

            // Check if spread covers fees
            if (bestBid > price1e18 + fee) {
                uint256 potentialProfit = ((bestBid - (price1e18 + fee)) *
                    bestBidSizeKuru) / 1e18;
                // Threshold: 0.03 USDC (3 cents) in 1e18 format = 3e16
                if (potentialProfit > 3e16) {
                    expectedProfit = potentialProfit;
                    profitable = true;
                    zeroForOne = false;

                    // Calc SqrtLimit with Margin
                    // Stop buying if Uni Price approaches BestBid. Leave 7bps margin for fees/slippage.
                    // Target = bestBid * (1 - 0.0007)
                    uint256 safeBid = (bestBid * 9993) / 10000;
                    uint256 rootBid = FixedPointMathLib.sqrt(safeBid);
                    uint160 limit = uint160(
                        FullMath.mulDiv(rootBid, 1 << 96, SQRT_PRICE_SCALE)
                    );

                    data = abi.encode(zeroForOne, amountInWei, limit);
                }
            }
        } else if (price1e18 > bestAsk) {
            // Reverse Arb: Buy on Kuru (Low), Sell on Uniswap (High)
            // We need to know how much we can buy on Kuru:
            // uint32 ticksToQueuery = 20; // Already defined above

            // Fee Calculation:
            // Uniswap Fee = 5 bps
            // Kuru Fee = 2 bps
            // Total = 7 bps
            uint256 fee = (price1e18 * 7) / 10000;
            // We can buy as long as Ask Price < Uniswap Price - Fee
            uint256 maxPrice = price1e18 - fee;

            (uint256 bestAskSizeKuru, ) = getAggregatedAskSize(
                ticksToQueuery,
                maxPrice
            );

            if (bestAskSizeKuru < 200e18) {
                return (
                    false,
                    true,
                    data,
                    price1e18,
                    bestBid,
                    bestAsk,
                    expectedProfit
                );
            }

            uint256 maxAmount;

            // Convert `bestAskSizeKuru` (MON) to USDC (`maxAmount`).
            // maxAmount [USDC] = bestAskSizeKuru [MON] * bestAsk [Price] / 1e18.
            maxAmount = (bestAskSizeKuru * bestAsk) / 1e18;

            // Truncate to Kuru Precision (Scalar = 1e7)
            {
                uint256 scalar = BASE_MULTIPLIER / SIZE_PRECISION;
                maxAmount = (maxAmount / scalar) * scalar;

                // SAFETY: Scale down by 0.7% to account for Kuru Fees (deducted from output) and rounding.
                maxAmount = (maxAmount * 9930) / 10000;
            }
            // ------------------------------------------------

            // We will borrow USDC to buy MON on Kuru
            // amountInWei here will represent the USDC amount to borrow
            uint256 amountInWei = maxAmount;

            // Check if spread covers fees
            if (bestAsk < price1e18 - fee) {
                // Scoped block to avoid Stack Too Deep
                {
                    // Profit in MON Value = (Spread * Size) / Price
                    // ((price1e18 - fee - bestAsk) * bestAskSizeKuru) / price1e18
                    uint256 potentialProfitMON = ((price1e18 - fee - bestAsk) *
                        bestAskSizeKuru) / price1e18;

                    if (potentialProfitMON > 1 ether) {
                        expectedProfit = potentialProfitMON;
                        profitable = true;
                        zeroForOne = true;

                        // Calc SqrtLimit with Margin
                        // Stop selling if Uni Price drops to BestAsk. Leave 7bps margin.
                        // Target = bestAsk * (1 + 0.0007)
                        uint256 safeAsk = (bestAsk * 10007) / 10000;
                        uint256 rootAsk = FixedPointMathLib.sqrt(safeAsk);
                        uint160 limit = uint160(
                            FullMath.mulDiv(rootAsk, 1 << 96, SQRT_PRICE_SCALE)
                        );

                        data = abi.encode(zeroForOne, amountInWei, limit);
                    }
                }
            }
        }
    }

    function execute() public returns (bool) {
        PoolKey memory key = getPoolKey(USDC_CURRENCY);
        PoolId id = key.toId();
        (uint160 sq, , , ) = PM.getSlot0(id);

        // 1. Sanity Check Prices & Determine Direction
        (uint256 bestBid, uint256 bestAsk) = OB_USDC.bestBidAsk();

        uint256 uniPrice1e18 = getUniswapPrice(USDC_CURRENCY);

        bool zeroForOne;
        uint256 kuruVolWei;
        uint160 sqrtLimit;
        uint256 maxUsdcSpend; // For Reverse Arb: max USDC to spend on Kuru

        uint256 fee = (uniPrice1e18 * 7) / 10000;

        if (uniPrice1e18 + fee < bestBid) {
            // Forward: Buy Uni (Low), Sell Kuru (High)
            // Limit: Stop buying if Uni Price > BestBid (minus fees + margin)
            zeroForOne = false;

            kuruVolWei = getAggregatedBidSize(50, uniPrice1e18 + fee);

            // Limit Price (SqrtX96)
            // Buffer: 10bps (0.1%)
            uint256 safeBid = (bestBid * 9990) / 10000;
            uint256 root = FixedPointMathLib.sqrt(safeBid);
            sqrtLimit = uint160(
                FullMath.mulDiv(root, 1 << 96, SQRT_PRICE_SCALE)
            );

            if (sqrtLimit <= sq) return false;
            maxUsdcSpend = 0; // Not used in Forward Arb
        } else if (uniPrice1e18 > bestAsk + fee && bestAsk > 0) {
            // Reverse: Sell Uni (High), Buy Kuru (Low)
            // Limit: Stop selling if Uni Price < BestAsk (plus fees + margin)
            zeroForOne = true;

            (kuruVolWei, maxUsdcSpend) = getAggregatedAskSize(
                50,
                uniPrice1e18 - fee
            );

            // Buffer: Scale down maxUsdcSpend by 0.3% to ensure monBought >= monDebt
            // after Kuru's 2bps taker fee (deducted from MON output)
            maxUsdcSpend = (maxUsdcSpend * 9970) / 10000;

            // Limit Price
            // Buffer: 7bps
            uint256 safeAsk = (bestAsk * 10007) / 10000;
            uint256 root = FixedPointMathLib.sqrt(safeAsk);
            sqrtLimit = uint160(
                FullMath.mulDiv(root, 1 << 96, SQRT_PRICE_SCALE)
            );

            if (sqrtLimit >= sq) return false;
        } else {
            return false;
        }

        if (kuruVolWei == 0) return false;

        bytes memory data = abi.encode(
            zeroForOne,
            kuruVolWei,
            sqrtLimit,
            maxUsdcSpend
        );
        PM.unlock(data);
        return true;
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        PoolKey memory key = getPoolKey(USDC_CURRENCY);
        (
            bool zeroForOne,
            uint256 kuruAmount,
            uint160 sqrtLimit,
            uint256 maxUsdcSpend
        ) = abi.decode(data, (bool, uint256, uint160, uint256));

        int256 amountSpecified;

        if (zeroForOne) {
            // Reverse Arb: Sell MON on Uniswap (high), Buy MON on Kuru (low)
            // Use exactOutput: positive amountSpecified = maxUsdcSpend (USDC to receive)
            // Per Uniswap V4: positive = exactOutput, negative = exactInput
            amountSpecified = int256(maxUsdcSpend);
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtLimit
            });
            BalanceDelta delta = PM.swap(key, params, "");

            // MON we need to repay to PM (sold on Uniswap)
            uint256 monDebt = uint256(uint128(-delta.amount0()));
            // USDC we received (should be exactly maxUsdcSpend)
            uint256 usdcCredit = uint256(uint128(delta.amount1()));

            // Take USDC from PM
            PM.take(key.currency1, address(this), usdcCredit);

            // Spend ALL USDC on Kuru (exactOutput ensures we got exactly what we need)
            uint96 quoteInput = uint96(
                (usdcCredit * PRICE_PRECISION) / QUOTE_MULTIPLIER
            );

            USDC.approve(address(OB_USDC), type(uint256).max);
            OB_USDC.placeAndExecuteMarketBuy(quoteInput, 0, false, false);

            PM.settle{value: monDebt}();

            if (address(this).balance > 0) {
                (bool sent, ) = payable(owner).call{
                    value: address(this).balance
                }("");
                require(sent, "ETH Repatriation failed");
            }
        } else {
            // Forward Arb: Scale down by 0.4% to account for Kuru taker fee + price precision
            amountSpecified = int256((kuruAmount * 9960) / 10000);
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtLimit
            });
            BalanceDelta delta = PM.swap(key, params, "");
            PM.take(
                key.currency0,
                address(this),
                uint256(uint128(delta.amount0()))
            );

            uint256 monCredit = uint256(uint128(delta.amount0()));
            uint256 usdcDebt = uint256(uint128(-delta.amount1()));

            uint96 monToSell = uint96(
                (monCredit * SIZE_PRECISION) / BASE_MULTIPLIER
            );

            OB_USDC.placeAndExecuteMarketSell{value: monCredit}(
                monToSell,
                0,
                false,
                false
            );

            // Settle USDC via Push (Sync -> Transfer -> Settle)
            PM.sync(key.currency1);
            USDC.transfer(address(PM), usdcDebt);
            PM.settle();

            // Repatriate Profit (USDC)
            uint256 bal = USDC.balanceOf(address(this));
            if (bal > 0) {
                USDC.transfer(owner, bal);
            }
        }
        return "";
    }

    function getAggregatedBidSize(
        uint32 ticksBid,
        uint256 minPrice
    ) public view returns (uint256 totalSizeWei) {
        uint256 totalSizeRaw;

        // Scale minPrice (1e18) to Raw Price (1e7)
        // 1e18 -> 1e7: Divide by 1e11
        uint256 minPriceRaw = minPrice / (BASE_MULTIPLIER / PRICE_PRECISION);

        // Request 'ticks' number of bids
        bytes memory data = OB_USDC.getL2Book(ticksBid, 0);

        assembly {
            // Skip 32 bytes (length) + 32 bytes (block number)
            let ptr := add(data, 64)

            // Loop 'ticks' times
            for {
                let i := 0
            } lt(i, ticksBid) {
                i := add(i, 1)
            } {
                // Read Price
                let price := mload(ptr)

                // If price is 0, we hit the end of the book/delimiter
                if iszero(price) {
                    break
                }

                // If price < minPriceRaw, we stop (bids are sorted descending)
                if lt(price, minPriceRaw) {
                    break
                }

                // Read Size (next 32 bytes)
                let size := mload(add(ptr, 32))

                // Check if size is Left-Aligned (Mainnet) or Right-Aligned (Standard/Fork)
                // uint96 max is ~7.9e28. If size > 1e30, it must be left-aligned.
                if gt(size, 1000000000000000000000000000000) {
                    size := shr(160, size)
                }

                // Add to total
                totalSizeRaw := add(totalSizeRaw, size)

                // Move pointer by 64 bytes (Price + Size)
                ptr := add(ptr, 64)
            }
        }

        // Convert Raw Size to Wei (Base Asset)
        // Base Asset is MON (18 decimals)
        // Formula: Wei = Raw * 1e18 / sizePrecision
        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / SIZE_PRECISION;
    }
    function getAggregatedAskSize(
        uint32 ticksAsk,
        uint256 maxPrice
    ) public view returns (uint256 totalSizeWei, uint256 totalCostUSDC) {
        uint256 pricePrecision = PRICE_PRECISION;
        uint256 sizePrecision = SIZE_PRECISION;
        uint256 quoteMultiplier = QUOTE_MULTIPLIER;

        uint256 totalSizeRaw;

        // Scale maxPrice (1e18) to Raw Price (1e7)
        uint256 maxPriceRaw = maxPrice / (BASE_MULTIPLIER / PRICE_PRECISION);

        // Request 'ticks' number of asks
        bytes memory data = OB_USDC.getL2Book(0, ticksAsk);

        assembly {
            // Skip 32 bytes (length) + 32 bytes (block number) + 32 bytes (Bid Delimiter)
            let ptr := add(data, 96)

            // Loop 'ticks' times
            for {
                let i := 0
            } lt(i, ticksAsk) {
                i := add(i, 1)
            } {
                // Read Price
                let price := mload(ptr)

                // If price is 0, we hit the end
                if iszero(price) {
                    break
                }

                // If price > maxPriceRaw, we stop (asks are sorted ascending)
                if gt(price, maxPriceRaw) {
                    break
                }

                // Read Size (next 32 bytes)
                let size := mload(add(ptr, 32))

                // Check if size is Left-Aligned (Mainnet) or Right-Aligned (Standard/Fork)
                if gt(size, 1000000000000000000000000000000) {
                    size := shr(160, size)
                }

                // Add to total size
                totalSizeRaw := add(totalSizeRaw, size)

                // Add to total cost (USDC)
                // Formula: Cost = (Size * Price * QuoteMult) / (SizePrec * PricePrec)

                let costRaw := mul(size, price)
                let costScaled := mul(costRaw, quoteMultiplier)
                let divisor := mul(sizePrecision, pricePrecision)
                let cost := div(costScaled, divisor)

                totalCostUSDC := add(totalCostUSDC, cost)

                // Move pointer by 64 bytes (Price + Size)
                ptr := add(ptr, 64)
            }
        }

        // Convert Raw Size to Wei
        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / SIZE_PRECISION;

        return (totalSizeWei, totalCostUSDC);
    }

    function getLiquidityInRange(
        Currency currency,
        int24 startTick,
        int24 endTick
    )
        public
        view
        returns (TickLiquidity[] memory initializedTicks, uint256 wordsScanned)
    {
        if (startTick >= endTick) revert("Invalid Range");

        PoolKey memory key = getPoolKey(currency);
        PoolId id = key.toId();
        int24 tickSpacing = key.tickSpacing;

        // Estimate max size to avoid OOG in view call if range is huge
        // For simplicity in this efficiency-focused snippet, we use a dynamic array
        TickLiquidity[] memory tempTicks = new TickLiquidity[](500);
        uint256 count = 0;

        // Align startTick to tickSpacing
        // We need to find the word containing startTick
        int24 compressed = startTick / tickSpacing;
        if (startTick < 0 && startTick % tickSpacing != 0) compressed--; // Round down

        // Start from the word containing the compressed tick
        int16 currentWordPos = int16(compressed >> 8);
        int16 endWordPos = int16((endTick / tickSpacing) >> 8);

        // We assume 1 word per iteration as a rough metric for gas
        wordsScanned = uint256(int256(endWordPos) - int256(currentWordPos)) + 1;

        for (int16 wordPos = currentWordPos; wordPos <= endWordPos; wordPos++) {
            uint256 mask = PM.getTickBitmap(id, wordPos);

            if (mask != 0) {
                // Iterate bits
                bool stop;
                (count, stop) = _scanWord(
                    id,
                    wordPos,
                    tickSpacing,
                    startTick,
                    endTick,
                    tempTicks,
                    count,
                    mask
                );
                if (stop) break;
            }
            if (count >= 500) break;
        }

        // Resize array
        initializedTicks = new TickLiquidity[](count);
        for (uint i = 0; i < count; i++) initializedTicks[i] = tempTicks[i];
    }

    function calculateMaxCapacity(
        Currency currency, // New parameter
        uint160 sqrtPriceCurrent,
        uint160 targetSqrtPrice,
        int24 currentTick,
        uint128 currentLiquidity
    ) internal view returns (uint256 maxAmount, uint256 wordsScanned) {
        bool zeroForOne = targetSqrtPrice < sqrtPriceCurrent;

        // Define range for getLiquidityInRange
        int24 tT = TickMath.getTickAtSqrtPrice(targetSqrtPrice);
        TickLiquidity[] memory ticks;
        if (zeroForOne) {
            if (tT >= currentTick) return (0, 0);
            (ticks, wordsScanned) = getLiquidityInRange(
                currency,
                tT,
                currentTick
            );
        } else {
            if (currentTick >= tT) return (0, 0);
            (ticks, wordsScanned) = getLiquidityInRange(
                currency,
                currentTick,
                tT
            );
        }

        // State variables for iteration
        uint160 sqrtPriceC = sqrtPriceCurrent;
        uint128 liquidity = currentLiquidity;

        if (zeroForOne) {
            // Price Decreasing (Token0 out, Token1 in). Iterate ticks from high to low.
            int256 firstTickIdx = -1;
            for (uint i = ticks.length; i > 0; i--) {
                if (ticks[i - 1].tick <= currentTick) {
                    firstTickIdx = int256(i - 1);
                    break;
                }
            }

            if (firstTickIdx == -1) {
                // No ticks
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        targetSqrtPrice,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                return (maxAmount, wordsScanned);
            }

            uint160 sqrtPriceLimitForFirstSegment = TickMath.getSqrtPriceAtTick(
                ticks[uint(firstTickIdx)].tick
            );
            if (sqrtPriceLimitForFirstSegment < targetSqrtPrice)
                sqrtPriceLimitForFirstSegment = targetSqrtPrice;

            if (sqrtPriceC > sqrtPriceLimitForFirstSegment) {
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        sqrtPriceLimitForFirstSegment,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                sqrtPriceC = nextSqrtP;
            }

            for (int256 i = firstTickIdx; i >= 0; i--) {
                TickLiquidity memory t = ticks[uint(i)];
                if (sqrtPriceC <= targetSqrtPrice) break;
                if (sqrtPriceC <= TickMath.getSqrtPriceAtTick(t.tick)) {
                    liquidity = uint128(int128(liquidity) - t.liquidityNet);
                    continue;
                }
                uint160 sqrtPriceNextTick = TickMath.getSqrtPriceAtTick(t.tick);
                uint160 sqrtPriceLimit = sqrtPriceNextTick;
                if (sqrtPriceLimit < targetSqrtPrice)
                    sqrtPriceLimit = targetSqrtPrice;
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        sqrtPriceLimit,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                sqrtPriceC = nextSqrtP;
                liquidity = uint128(int128(liquidity) - t.liquidityNet);
            }

            if (sqrtPriceC > targetSqrtPrice) {
                (, , uint256 amountOut, ) = SwapMath.computeSwapStep(
                    sqrtPriceC,
                    targetSqrtPrice,
                    liquidity,
                    type(int256).max,
                    500
                );
                maxAmount += amountOut;
            }
        } else {
            // Price Increasing. Iterate ticks from low to high.
            int256 firstTickIdx = -1;
            for (uint i = 0; i < ticks.length; i++) {
                if (ticks[i].tick >= currentTick) {
                    firstTickIdx = int256(i);
                    break;
                }
            }

            if (firstTickIdx == -1) {
                // No ticks
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        targetSqrtPrice,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                return (maxAmount, wordsScanned);
            }

            uint160 sqrtPriceLimitForFirstSegment = TickMath.getSqrtPriceAtTick(
                ticks[uint(firstTickIdx)].tick
            );
            if (sqrtPriceLimitForFirstSegment > targetSqrtPrice)
                sqrtPriceLimitForFirstSegment = targetSqrtPrice;

            if (sqrtPriceC < sqrtPriceLimitForFirstSegment) {
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        sqrtPriceLimitForFirstSegment,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                sqrtPriceC = nextSqrtP;
            }

            for (int256 i = firstTickIdx; i < int256(ticks.length); i++) {
                TickLiquidity memory t = ticks[uint(i)];
                if (sqrtPriceC >= targetSqrtPrice) break;
                if (sqrtPriceC >= TickMath.getSqrtPriceAtTick(t.tick)) {
                    liquidity = uint128(int128(liquidity) + t.liquidityNet);
                    continue;
                }
                uint160 sqrtPriceNextTick = TickMath.getSqrtPriceAtTick(t.tick);
                uint160 sqrtPriceLimit = sqrtPriceNextTick;
                if (sqrtPriceLimit > targetSqrtPrice)
                    sqrtPriceLimit = targetSqrtPrice;
                (uint160 nextSqrtP, , uint256 amountOut, ) = SwapMath
                    .computeSwapStep(
                        sqrtPriceC,
                        sqrtPriceLimit,
                        liquidity,
                        type(int256).max,
                        500
                    );
                maxAmount += amountOut;
                sqrtPriceC = nextSqrtP;
                liquidity = uint128(int128(liquidity) + t.liquidityNet);
            }

            if (sqrtPriceC < targetSqrtPrice) {
                (, , uint256 amountOut, ) = SwapMath.computeSwapStep(
                    sqrtPriceC,
                    targetSqrtPrice,
                    liquidity,
                    type(int256).max,
                    500
                );
                maxAmount += amountOut;
            }
        }
    }

    function _scanWord(
        PoolId id,
        int16 wordPos,
        int24 tickSpacing,
        int24 startTick,
        int24 endTick,
        TickLiquidity[] memory tempTicks,
        uint256 count,
        uint256 mask
    ) private view returns (uint256, bool) {
        for (uint8 i = 0; i < 255; i++) {
            if ((mask & (1 << i)) != 0) {
                int24 compressedTick = (int24(wordPos) << 8) + int24(uint24(i));
                int24 actualTick = compressedTick * tickSpacing;

                if (actualTick > endTick) return (count, true);
                if (actualTick >= startTick) {
                    (
                        tempTicks[count].liquidityGross,
                        tempTicks[count].liquidityNet
                    ) = PM.getTickLiquidity(id, actualTick);
                    tempTicks[count].tick = actualTick;
                    count++;
                    if (count >= 500) return (count, true);
                }
            }
        }
        return (count, false);
    }
}
