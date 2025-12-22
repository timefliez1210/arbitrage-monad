// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    FixedPointMathLib
} from "@kuru/contracts/libraries/FixedPointMathLib.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";

import {
    IPancakeV3Pool,
    IPancakeV3SwapCallback
} from "./interfaces/IPancakeV3Pool.sol";
import {IWMON} from "./interfaces/IWMON.sol";

/// @title ArbitragePcsUniUSDC
/// @notice Arbitrage between PancakeSwap V3 WMON/USDC and Uniswap V4 MON/USDC pools
/// @dev PCS Pool: token0=WMON, token1=USDC (sqrtPrice = sqrt(USDC/WMON)) - DIRECT
///      Uni Pool: currency0=MON, currency1=USDC (sqrtPrice = sqrt(USDC/MON)) - DIRECT
///      Both pools have DIRECT relationship: higher sqrtPrice = more expensive MON
contract ArbitragePcsUniUSDC is IPancakeV3SwapCallback, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ============ ERRORS ============
    error Unauthorized();
    error InsufficientOutput();
    error NotProfitable();

    // ============ CONSTANTS ============
    uint256 constant MIN_TRADE = 1e18; // 1 MON minimum
    uint256 constant MAX_TRADE = 1000e18; // 1000 MON maximum
    uint256 constant SAFETY_FACTOR = 3000; // 30% of calculated tradeable (in basis points)

    // ============ IMMUTABLES ============
    IPancakeV3Pool public immutable PCS_POOL;
    IPoolManager public immutable PM;
    IWMON public immutable WMON;
    IERC20 public immutable USDC;
    address public immutable owner;

    Currency constant MON_CURRENCY = Currency.wrap(address(0));
    Currency public immutable USDC_CURRENCY;

    uint256 constant BASE_MULTIPLIER = 1e18;
    uint256 constant PRICE_SCALE_FACTOR = 1e30; // 18 + 18 - 6
    uint256 public immutable SQRT_PRICE_SCALE;

    // ============ CONSTRUCTOR ============
    constructor(
        address _pcsPool,
        address _poolManager,
        address _wmon,
        address _usdc,
        address _owner
    ) {
        PCS_POOL = IPancakeV3Pool(_pcsPool);
        PM = IPoolManager(_poolManager);
        WMON = IWMON(_wmon);
        USDC = IERC20(_usdc);
        USDC_CURRENCY = Currency.wrap(_usdc);
        owner = _owner;

        SQRT_PRICE_SCALE = FixedPointMathLib.sqrt(PRICE_SCALE_FACTOR);
    }

    receive() external payable {}

    // ============ POOL KEY ============

    function getPoolKey() public view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON_CURRENCY,
                currency1: USDC_CURRENCY,
                fee: 500,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            });
    }

    // ============ PRICE QUERIES ============

    /// @notice Get PCS price (USDC per MON in 1e18)
    /// @dev Pool is WMON/USDC: token0=WMON, token1=USDC (DIRECT relationship)
    function getPcsPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                PRICE_SCALE_FACTOR,
                1 << 192
            );
    }

    /// @notice Get PCS sqrtPriceX96 and liquidity
    function getPcsState()
        public
        view
        returns (uint160 sqrtPriceX96, uint128 liquidity)
    {
        (sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();
        liquidity = PCS_POOL.liquidity();
    }

    /// @notice Get Uni V4 price (USDC per MON in 1e18)
    function getUniPrice() public view returns (uint256) {
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                PRICE_SCALE_FACTOR,
                1 << 192
            );
    }

    /// @notice Get Uni V4 sqrtPriceX96 and liquidity
    function getUniState()
        public
        view
        returns (uint160 sqrtPriceX96, uint128 liquidity)
    {
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (sqrtPriceX96, , , ) = PM.getSlot0(id);
        liquidity = PM.getLiquidity(id);
    }

    // ============ TRADE SIZE ESTIMATION ============

    /// @notice Calculate optimal trade size using Uniswap V3/V4 liquidity math
    /// @dev Both pools have DIRECT sqrtPrice relationship (same formula)
    function estimateTradeSize()
        public
        view
        returns (uint256 tradeSize, bool isForward)
    {
        (uint160 pcsSqrt, uint128 pcsL) = getPcsState();
        (uint160 uniSqrt, uint128 uniL) = getUniState();

        uint256 pcsPrice = FullMath.mulDiv(
            uint256(pcsSqrt) * uint256(pcsSqrt),
            PRICE_SCALE_FACTOR,
            1 << 192
        );
        uint256 uniPrice = FullMath.mulDiv(
            uint256(uniSqrt) * uint256(uniSqrt),
            PRICE_SCALE_FACTOR,
            1 << 192
        );

        if (pcsPrice < uniPrice) {
            isForward = true;
        } else if (uniPrice < pcsPrice) {
            isForward = false;
        } else {
            return (0, false); // No opportunity
        }

        // Target price (midpoint)
        uint256 targetPrice = (pcsPrice + uniPrice) / 2;
        uint160 targetSqrt = _priceToSqrtPrice(targetPrice);

        // Both pools have DIRECT relationship, so same formula applies
        // For token0 (MON/WMON): ΔX = L × (√Pb - √Pa) / (√Pa × √Pb)

        // PCS tradeable
        uint256 deltaSqrtPcs = pcsSqrt > targetSqrt
            ? uint256(pcsSqrt) - uint256(targetSqrt)
            : uint256(targetSqrt) - uint256(pcsSqrt);
        uint256 sqrtProductPcs = FullMath.mulDiv(
            uint256(pcsSqrt),
            uint256(targetSqrt),
            1 << 96
        );
        uint256 pcsTradeableX = sqrtProductPcs > 0
            ? FullMath.mulDiv(uint256(pcsL), deltaSqrtPcs, sqrtProductPcs)
            : 0;

        // Uni tradeable
        uint256 deltaSqrtUni = uniSqrt > targetSqrt
            ? uint256(uniSqrt) - uint256(targetSqrt)
            : uint256(targetSqrt) - uint256(uniSqrt);
        uint256 sqrtProductUni = FullMath.mulDiv(
            uint256(uniSqrt),
            uint256(targetSqrt),
            1 << 96
        );
        uint256 uniTradeableX = sqrtProductUni > 0
            ? FullMath.mulDiv(uint256(uniL), deltaSqrtUni, sqrtProductUni)
            : 0;

        // Take minimum (bottleneck)
        tradeSize = pcsTradeableX < uniTradeableX
            ? pcsTradeableX
            : uniTradeableX;

        // Apply safety factor (30%)
        tradeSize = (tradeSize * SAFETY_FACTOR) / 10000;

        // Clamp to bounds
        if (tradeSize < MIN_TRADE) tradeSize = MIN_TRADE;
        if (tradeSize > MAX_TRADE) tradeSize = MAX_TRADE;
    }

    // ============ KEEPER PROFIT ============

    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        (uint256 tradeSize, bool isForward) = estimateTradeSize();

        if (tradeSize == 0) return (false, 0);

        uint256 pcsPrice = getPcsPrice();
        uint256 uniPrice = getUniPrice();

        uint256 feeBuffer = (pcsPrice * 15) / 10000; // 15bps

        uint256 spread;
        if (isForward && pcsPrice + feeBuffer < uniPrice) {
            spread = uniPrice - pcsPrice - feeBuffer;
        } else if (!isForward && uniPrice + feeBuffer < pcsPrice) {
            spread = pcsPrice - uniPrice - feeBuffer;
        } else {
            return (false, 0);
        }

        expectedProfit = FullMath.mulDiv(spread, tradeSize, 1e18);
        profitable = expectedProfit > 1e16;
    }

    // ============ EXECUTE (AUTONOMOUS) ============

    function execute() external returns (bool) {
        (uint256 tradeSize, bool isForward) = estimateTradeSize();

        if (tradeSize < MIN_TRADE) return false;

        uint256 pcsPrice = getPcsPrice();
        uint256 uniPrice = getUniPrice();
        uint256 feeBuffer = (pcsPrice * 10) / 10000;

        if (isForward && pcsPrice + feeBuffer < uniPrice) {
            _executeForward(tradeSize, uniPrice);
            return true;
        } else if (!isForward && uniPrice + feeBuffer < pcsPrice) {
            _executeReverse(tradeSize, pcsPrice);
            return true;
        }

        return false;
    }

    // ============ FORWARD: PCS → UNI ============

    function _executeForward(uint256 amountMon, uint256 uniPrice) internal {
        // PCS: buying WMON (zeroForOne=false, USDC→WMON)
        // DIRECT relationship: higher price = higher sqrtPrice
        // Limit: stop if pcsPrice rises to uniPrice
        uint256 safeBid = (uniPrice * 9980) / 10000;
        uint160 pcsLimit = _priceToSqrtPrice(safeBid);

        PCS_POOL.swap(
            address(this),
            false, // USDC → WMON
            -int256(amountMon),
            pcsLimit,
            abi.encode(true, amountMon, uniPrice)
        );
    }

    // ============ REVERSE: UNI → PCS ============

    function _executeReverse(uint256 amountMon, uint256 pcsPrice) internal {
        // Uni: buying MON (zeroForOne=false)
        uint256 safeAsk = (pcsPrice * 9980) / 10000;
        uint160 uniLimit = _priceToSqrtPrice(safeAsk);

        PM.unlock(abi.encode(false, amountMon, pcsPrice, uniLimit));
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta, // WMON delta
        int256 amount1Delta, // USDC delta
        bytes calldata data
    ) external {
        if (msg.sender != address(PCS_POOL)) revert Unauthorized();

        (bool isForward, , uint256 uniPrice) = abi.decode(
            data,
            (bool, uint256, uint256)
        );

        if (isForward) {
            uint256 wmonReceived = uint256(-amount0Delta);
            uint256 usdcOwed = uint256(amount1Delta);

            WMON.withdraw(wmonReceived);

            uint160 uniLimit = _priceToSqrtPrice((uniPrice * 9993) / 10000);
            PM.unlock(abi.encode(true, wmonReceived, usdcOwed, uniLimit));
        }
    }

    // ============ UNI V4 CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(PM)) revert Unauthorized();

        (
            bool isForward,
            uint256 amountMon,
            uint256 amountUsdcOrPcsPrice,
            uint160 sqrtLimit
        ) = abi.decode(data, (bool, uint256, uint256, uint160));

        if (isForward) {
            uint256 usdcOwed = amountUsdcOrPcsPrice;

            PoolKey memory key = getPoolKey();
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true, // MON → USDC
                    amountSpecified: int256(amountMon),
                    sqrtPriceLimitX96: sqrtLimit
                }),
                ""
            );

            int128 monSpent = delta.amount0();
            int128 usdcReceived = -delta.amount1();

            if (monSpent > 0) {
                PM.settle{value: uint256(uint128(monSpent))}();
            }

            if (usdcReceived > 0) {
                PM.take(
                    USDC_CURRENCY,
                    address(this),
                    uint256(uint128(usdcReceived))
                );
            }

            uint256 usdcBal = USDC.balanceOf(address(this));
            if (usdcBal < usdcOwed) revert InsufficientOutput();
            USDC.transfer(address(PCS_POOL), usdcOwed);

            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        } else {
            uint256 pcsPrice = amountUsdcOrPcsPrice;

            PoolKey memory key = getPoolKey();
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false, // USDC → MON
                    amountSpecified: -int256(amountMon),
                    sqrtPriceLimitX96: sqrtLimit
                }),
                ""
            );

            int128 monReceived = -delta.amount0();
            int128 usdcDebt = delta.amount1();

            if (monReceived > 0) {
                PM.take(
                    MON_CURRENCY,
                    address(this),
                    uint256(uint128(monReceived))
                );
            }

            uint256 monBal = address(this).balance;
            WMON.deposit{value: monBal}();

            // Sell WMON on PCS: zeroForOne=true (WMON → USDC)
            uint160 pcsLimit = _priceToSqrtPrice((pcsPrice * 10007) / 10000);

            PCS_POOL.swap(
                address(this),
                true, // WMON → USDC
                int256(WMON.balanceOf(address(this))),
                pcsLimit,
                abi.encode(false)
            );

            uint256 usdcBal = USDC.balanceOf(address(this));
            if (int256(usdcBal) < usdcDebt) revert InsufficientOutput();

            USDC.transfer(address(PM), uint256(uint128(usdcDebt)));
            PM.settle();

            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        }

        return "";
    }

    // ============ SQRT PRICE CONVERSION ============

    /// @notice Convert USDC/MON price (1e18) to sqrtPriceX96
    /// @dev Both PCS and Uni have DIRECT relationship
    function _priceToSqrtPrice(
        uint256 priceUsdcPerMon
    ) internal pure returns (uint160) {
        uint256 sqrtPrice = FixedPointMathLib.sqrt(
            FullMath.mulDiv(priceUsdcPerMon, 1 << 192, PRICE_SCALE_FACTOR)
        );
        return uint160(sqrtPrice);
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");

        if (address(this).balance > 0) {
            payable(owner).call{value: address(this).balance}("");
        }

        uint256 wmonBal = WMON.balanceOf(address(this));
        if (wmonBal > 0) {
            WMON.withdraw(wmonBal);
            payable(owner).call{value: address(this).balance}("");
        }

        uint256 usdcBal = USDC.balanceOf(address(this));
        if (usdcBal > 0) {
            USDC.transfer(owner, usdcBal);
        }
    }
}
