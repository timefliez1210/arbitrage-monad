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
    /// @dev Uses 20 tick depth (vs 50) for speed. Returns only essential data.
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
            uint256 kuruSize = getAggregatedBidSize(20, price1e18 + fee); // 20 ticks
            if (kuruSize > 0) {
                // Use 90% of spread to better reflect actual execution
                // effectiveSpread = (bestBid - price1e18) * 0.9
                uint256 effectiveSpread = ((bestBid - price1e18) * 94) / 100;
                // Subtract execute() safety margin: 20bps price + 25bps size = 45bps
                uint256 executeMargin = (bestBid * 45) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        1e18;
                    // Threshold: 0.03 USDC (3 cents)
                    if (expectedProfit > 15e15) {
                        profitable = true;
                    }
                }
            }
        }
        // Reverse check: Uni price > Kuru ask
        else if (
            price1e18 > bestAsk && bestAsk > 0 && bestAsk < price1e18 - fee
        ) {
            (uint256 kuruSize, ) = getAggregatedAskSize(20, price1e18 - fee); // 20 ticks
            if (kuruSize > 0) {
                // Use 90% of spread to better reflect actual execution
                // effectiveSpread = (price1e18 - bestAsk) * 0.9
                uint256 effectiveSpread = ((price1e18 - bestAsk) * 94) / 100;
                // Subtract execute() safety margins: 7bps price + 20bps quantity = 27bps
                uint256 executeMargin = (bestAsk * 27) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        price1e18;
                    // Threshold: 0.75 MON
                    if (expectedProfit > 0.75 ether) {
                        profitable = true;
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
            // Buffer: 20bps (0.2%)
            uint256 safeBid = (bestBid * 9980) / 10000;
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

            // Buffer: Scale down maxUsdcSpend by 0.2% to ensure monBought >= monDebt
            // after Kuru's 2bps taker fee (deducted from MON output)
            maxUsdcSpend = (maxUsdcSpend * 9980) / 10000;

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
            // Forward Arb: Scale down by 0.25% to account for Kuru taker fee + price precision
            amountSpecified = int256((kuruAmount * 9975) / 10000);
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
}
