//SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";

/// @title ArbitrageAUSDUSDC
/// @notice Arbitrage between AUSD/USDC Uniswap V4 pool and Kuru orderbook
/// @dev Both AUSD and USDC have 6 decimals. Kuru bestBidAsk() returns 1e18 scaled prices.
contract ArbitrageAUSDUSDC is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    error USDC_BALANCE_NOT_ENOUGH(uint256 balance, uint256 needed);
    error AUSD_BALANCE_NOT_ENOUGH(uint256 balance, uint256 needed);
    error SWAP_FAILED(bytes reason);

    // ============ CONSTANTS ============

    //// AUSD (Base) - 6 decimals
    IERC20 constant AUSD = IERC20(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
    address constant AUSD_ADDRESS = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    Currency constant AUSD_CURRENCY =
        Currency.wrap(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);

    //// USDC (Quote) - 6 decimals
    IERC20 constant USDC = IERC20(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
    address constant USDC_ADDRESS = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    Currency constant USDC_CURRENCY =
        Currency.wrap(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);

    IPoolManager public constant PM =
        IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);

    // AUSD/USDC Market on Kuru
    IOrderBook public constant OB =
        IOrderBook(0x8cF49e35D73B19433FF4d4421637AABB680dc9Cc);

    // Kuru market params (verified on-chain)
    // pricePrecision = 1e7, sizePrecision = 1e6
    // BUT bestBidAsk() returns 1e18 scaled prices!
    uint256 constant PRICE_PRECISION = 1e7;
    uint256 constant NUM_TICKS = 50;
    uint256 constant QUOTE_MULTIPLIER = 1e6; // USDC decimals
    uint256 constant BASE_MULTIPLIER = 1e6; // AUSD decimals

    // ============ STATE ============

    address public immutable owner;

    // ============ CONSTRUCTOR ============

    constructor(address _owner) {
        owner = _owner;
    }

    // ============ POOL KEY ============

    function getPoolKey() public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: AUSD_CURRENCY,
                currency1: USDC_CURRENCY,
                fee: 50, // 0.005% = 0.5 bps
                tickSpacing: 1,
                hooks: IHooks(address(0))
            });
    }

    function getUniswapPrice() internal view returns (uint256) {
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        // For same-decimal tokens (6/6), price = sqrtPrice^2 / 2^192 * 1e18
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                1e18,
                1 << 192
            );
    }

    function getSqrtPriceX96() internal view returns (uint160) {
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        return sqrtPriceX96;
    }

    // ============ KEEPER PROFIT (LIGHTWEIGHT) ============

    /// @notice Lightweight profit check for off-chain keepers
    /// @dev Uses 20 tick depth for speed.
    /// NOTE: Both Uni price and Kuru bestBidAsk return 1e18 scaled prices!
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        uint256 price1e18 = getUniswapPrice();
        (uint256 bestBid, uint256 bestAsk) = OB.bestBidAsk(); // Already 1e18!

        // Total fees: Uni 0.5bps + Kuru 2bps = ~3bps (conservative: 7bps)
        uint256 fee = (price1e18 * 7) / 10000;

        // Forward: Uni price < Kuru bid → Buy AUSD on Uni, sell on Kuru
        if (price1e18 + fee < bestBid) {
            uint256 kuruSize = getAggregatedBidSize(20, price1e18 + fee);
            if (kuruSize > 0) {
                // Use 95% of spread to better reflect actual execution
                uint256 effectiveSpread = ((bestBid - price1e18) * 95) / 100;
                // Margin: 20bps price + 25bps size = 45bps
                uint256 executeMargin = (bestBid * 45) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        1e18;
                    if (expectedProfit > 1e5) {
                        // 0.1 USDC threshold
                        profitable = true;
                    }
                }
            }
        }
        // Reverse: Uni price > Kuru ask → Buy AUSD on Kuru, sell on Uni
        else if (price1e18 > bestAsk + fee && bestAsk > 0) {
            (uint256 kuruSize, ) = getAggregatedAskSize(20, price1e18 - fee);
            if (kuruSize > 0) {
                // Use 95% of spread to better reflect actual execution
                uint256 effectiveSpread = ((price1e18 - bestAsk) * 95) / 100;
                // Margin: 7bps price + 20bps size = 27bps
                uint256 executeMargin = (bestAsk * 27) / 10000;
                if (effectiveSpread > fee + executeMargin) {
                    expectedProfit =
                        ((effectiveSpread - fee - executeMargin) * kuruSize) /
                        price1e18;
                    if (expectedProfit > 1e6) {
                        // 1 AUSD threshold
                        profitable = true;
                    }
                }
            }
        }
    }

    // ============ EXECUTE ============

    function execute() public returns (bool) {
        uint160 sqrtPriceX96 = getSqrtPriceX96();
        uint256 price1e18 = getUniswapPrice();
        (uint256 bestBid, uint256 bestAsk) = OB.bestBidAsk(); // Already 1e18!

        uint256 fee = (price1e18 * 7) / 10000;

        bool zeroForOne;
        uint256 kuruVolWei;
        uint160 sqrtLimit;
        uint256 maxUsdcSpend;

        if (price1e18 + fee < bestBid) {
            // Forward: Buy AUSD on Uni (low), Sell on Kuru (high)
            zeroForOne = false; // USDC -> AUSD

            kuruVolWei = getAggregatedBidSize(NUM_TICKS, price1e18 + fee);

            // Limit: stop buying if Uni price >= bestBid - 20bps margin
            uint256 safeBid = (bestBid * 9980) / 10000;
            sqrtLimit = _priceToSqrtPrice(safeBid);

            // For zeroForOne=false (buying AUSD), sqrtLimit must be > current
            if (sqrtLimit <= sqrtPriceX96) return false;
        } else if (price1e18 > bestAsk + fee && bestAsk > 0) {
            // Reverse: Buy AUSD on Kuru (low), Sell on Uni (high)
            zeroForOne = true; // AUSD -> USDC

            (kuruVolWei, maxUsdcSpend) = getAggregatedAskSize(
                NUM_TICKS,
                price1e18 - fee
            );
            maxUsdcSpend = (maxUsdcSpend * 9980) / 10000; // 0.2% buffer

            // Limit: stop selling if Uni price <= bestAsk + 7bps margin
            uint256 safeAsk = (bestAsk * 10007) / 10000;
            sqrtLimit = _priceToSqrtPrice(safeAsk);

            // For zeroForOne=true (selling AUSD), sqrtLimit must be < current
            if (sqrtLimit >= sqrtPriceX96) return false;
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
        require(msg.sender == address(PM), "Only PM");

        (bool zeroForOne, uint256 kuruVolWei, , uint256 maxUsdcSpend) = abi
            .decode(data, (bool, uint256, uint160, uint256));

        PoolKey memory key = getPoolKey();

        if (zeroForOne) {
            // Reverse Arb: Buy AUSD on Kuru (low), Sell AUSD on Uni (high)

            // Step 1: Borrow USDC from PM
            PM.take(USDC_CURRENCY, address(this), maxUsdcSpend);

            // Step 2: Buy AUSD on Kuru with borrowed USDC
            USDC.approve(address(OB), type(uint256).max);
            (, uint96 sizePrecision, , , , , , , , , ) = OB.getMarketParams();
            uint96 quoteInput = uint96(
                (maxUsdcSpend * PRICE_PRECISION) / QUOTE_MULTIPLIER
            );
            OB.placeAndExecuteMarketBuy(quoteInput, 0, false, false);

            // Step 3: Sell AUSD on Uniswap for USDC (exact output to repay borrow)
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: true, // AUSD -> USDC
                amountSpecified: int256(maxUsdcSpend), // Exact output USDC
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            BalanceDelta delta = PM.swap(key, params, "");
            uint256 ausdToPay = uint256(uint128(-delta.amount0()));

            uint256 ausdBalance = AUSD.balanceOf(address(this));
            if (ausdBalance < ausdToPay) {
                revert AUSD_BALANCE_NOT_ENOUGH(ausdBalance, ausdToPay);
            }

            // Settle AUSD to PM
            PM.sync(AUSD_CURRENCY);
            AUSD.transfer(address(PM), ausdToPay);
            PM.settle();

            // Profit is remaining AUSD
            uint256 profit = AUSD.balanceOf(address(this));
            if (profit > 0) {
                AUSD.transfer(owner, profit);
            }
        } else {
            // Forward Arb: Buy AUSD on Uni (low), Sell AUSD on Kuru (high)

            // Step 1: Borrow AUSD from PM
            PM.take(AUSD_CURRENCY, address(this), kuruVolWei);

            // Step 2: Swap USDC -> AUSD on Uni to repay borrow (exact output)
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: false, // USDC -> AUSD
                amountSpecified: int256(kuruVolWei), // Exact output AUSD
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });

            BalanceDelta delta = PM.swap(key, params, "");
            uint256 usdcToPay = uint256(uint128(-delta.amount1()));

            // Step 3: Sell AUSD on Kuru for USDC
            (, uint96 sizePrecision, , , , , , , , , ) = OB.getMarketParams();
            uint96 amountToSell = uint96(
                (kuruVolWei * sizePrecision) / BASE_MULTIPLIER
            );
            AUSD.approve(address(OB), type(uint256).max);
            OB.placeAndExecuteMarketSell(amountToSell, 0, false, false);

            uint256 usdcBalance = USDC.balanceOf(address(this));
            if (usdcBalance < usdcToPay) {
                revert USDC_BALANCE_NOT_ENOUGH(usdcBalance, usdcToPay);
            }

            // Settle USDC to PM
            PM.sync(USDC_CURRENCY);
            USDC.transfer(address(PM), usdcToPay);
            PM.settle();

            // Profit is remaining USDC
            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        }

        return "";
    }

    // ============ INTERNAL HELPERS ============

    function _priceToSqrtPrice(
        uint256 price1e18
    ) internal pure returns (uint160) {
        // For same-decimal tokens (6/6): sqrtPrice = sqrt(price) * 2^96 / sqrt(1e18)
        uint256 root = FixedPointMathLib.sqrt(price1e18);
        return uint160((root << 96) / 1e9);
    }

    // ============ ORDERBOOK HELPERS ============

    /// @notice Get aggregated bid volume above minPrice
    /// @dev minPrice is in 1e18 scale, converts to raw pricePrecision for L2Book
    function getAggregatedBidSize(
        uint256 ticksBid,
        uint256 minPrice
    ) public view returns (uint256 totalSizeWei) {
        (, uint96 sizePrecision, , , , , , , , , ) = OB.getMarketParams();

        uint256 totalSizeRaw;
        // Convert 1e18 price to raw pricePrecision (1e7)
        uint256 minPriceRaw = (minPrice * PRICE_PRECISION) / 1e18;

        bytes memory data = OB.getL2Book(uint32(ticksBid), 0);

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

    /// @notice Get aggregated ask volume below maxPrice
    function getAggregatedAskSize(
        uint256 ticksAsk,
        uint256 maxPrice
    ) public view returns (uint256 totalSizeWei, uint256 totalCostUSDC) {
        (, uint96 sizePrecision, , , , , , , , , ) = OB.getMarketParams();

        uint256 totalSizeRaw;
        // Convert 1e18 price to raw pricePrecision (1e7)
        uint256 maxPriceRaw = (maxPrice * PRICE_PRECISION) / 1e18;

        bytes memory data = OB.getL2Book(0, uint32(ticksAsk));

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

                // Cost in USDC = size * price / pricePrecision
                let costRaw := mul(size, price)
                let cost := div(costRaw, 10000000) // PRICE_PRECISION = 1e7
                totalCostUSDC := add(totalCostUSDC, cost)

                ptr := add(ptr, 64)
            }
        }

        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / sizePrecision;
    }
}
