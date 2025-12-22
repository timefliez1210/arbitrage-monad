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

/// @title ArbitragePcsUniAUSD
/// @notice Arbitrage between PancakeSwap V3 AUSD/WMON and Uniswap V4 MON/AUSD pools
/// @dev PCS Pool: token0=AUSD, token1=WMON (sqrtPrice = sqrt(WMON/AUSD)) - INVERSE
///      Uni Pool: currency0=MON, currency1=AUSD (sqrtPrice = sqrt(AUSD/MON)) - DIRECT
///      These are INVERSELY related: PCS sqrtPrice HIGH = Uni sqrtPrice LOW
contract ArbitragePcsUniAUSD is IPancakeV3SwapCallback, IUnlockCallback {
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
    IERC20 public immutable AUSD;
    address public immutable owner;

    Currency constant MON_CURRENCY = Currency.wrap(address(0));
    Currency public immutable AUSD_CURRENCY;

    uint256 constant BASE_MULTIPLIER = 1e18;
    uint256 constant PRICE_SCALE_FACTOR = 1e30; // 18 + 18 - 6
    uint256 public immutable SQRT_PRICE_SCALE;

    // ============ CONSTRUCTOR ============
    constructor(
        address _pcsPool,
        address _poolManager,
        address _wmon,
        address _ausd,
        address _owner
    ) {
        PCS_POOL = IPancakeV3Pool(_pcsPool);
        PM = IPoolManager(_poolManager);
        WMON = IWMON(_wmon);
        AUSD = IERC20(_ausd);
        AUSD_CURRENCY = Currency.wrap(_ausd);
        owner = _owner;

        SQRT_PRICE_SCALE = FixedPointMathLib.sqrt(PRICE_SCALE_FACTOR);
    }

    receive() external payable {}

    // ============ POOL KEY ============

    function getPoolKey() public view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON_CURRENCY,
                currency1: AUSD_CURRENCY,
                fee: 500,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            });
    }

    // ============ PRICE QUERIES ============

    /// @notice Get PCS price (AUSD per MON in 1e18)
    function getPcsPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        return
            FullMath.mulDiv(
                PRICE_SCALE_FACTOR,
                1 << 192,
                sqrtPrice * sqrtPrice
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

    /// @notice Get Uni V4 price (AUSD per MON in 1e18)
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
    /// @dev Uses ΔY = L × |√Pb - √Pa| to estimate how much MON we can trade
    ///      within the current liquidity to close the price gap
    /// @return tradeSize Recommended trade size in MON (1e18)
    /// @return isForward true = PCS→Uni, false = Uni→PCS
    function estimateTradeSize()
        public
        view
        returns (uint256 tradeSize, bool isForward)
    {
        // Get state from both pools
        (uint160 pcsSqrt, uint128 pcsL) = getPcsState();
        (uint160 uniSqrt, uint128 uniL) = getUniState();

        // Convert to comparable prices (AUSD per MON)
        uint256 pcsPrice = FullMath.mulDiv(
            PRICE_SCALE_FACTOR,
            1 << 192,
            uint256(pcsSqrt) * uint256(pcsSqrt)
        );
        uint256 uniPrice = FullMath.mulDiv(
            uint256(uniSqrt) * uint256(uniSqrt),
            PRICE_SCALE_FACTOR,
            1 << 192
        );

        if (pcsPrice >= uniPrice) {
            // No forward opportunity, check reverse
            if (uniPrice >= pcsPrice) return (0, false); // No opportunity
            isForward = false;
        } else {
            isForward = true;
        }

        // Calculate target price (midpoint where arb closes)
        // After arb: both prices should meet somewhere in between
        uint256 targetPrice = (pcsPrice + uniPrice) / 2;

        // Convert target to sqrtPrice for each pool
        uint160 targetSqrtPcs = _priceToSqrtPricePcs(targetPrice);
        uint160 targetSqrtUni = _priceToSqrtPriceUni(targetPrice);

        // Calculate tradeable amount for each pool using ΔY = L × |√Pb - √Pa|
        // For PCS (WMON is token1): ΔY gives us WMON/MON amount
        // For Uni (MON is token0): Need different formula

        // PCS tradeable (in WMON terms, which ≈ MON)
        uint256 deltaSqrtPcs = pcsSqrt > targetSqrtPcs
            ? uint256(pcsSqrt) - uint256(targetSqrtPcs)
            : uint256(targetSqrtPcs) - uint256(pcsSqrt);
        uint256 pcsTradeableY = FullMath.mulDiv(
            uint256(pcsL),
            deltaSqrtPcs,
            1 << 96
        );

        // Uni tradeable (in MON terms)
        // For token0 (MON): ΔX = L × (1/√Pa - 1/√Pb) = L × (√Pb - √Pa) / (√Pa × √Pb)
        uint256 deltaSqrtUni = uniSqrt > targetSqrtUni
            ? uint256(uniSqrt) - uint256(targetSqrtUni)
            : uint256(targetSqrtUni) - uint256(uniSqrt);
        uint256 sqrtProduct = FullMath.mulDiv(
            uint256(uniSqrt),
            uint256(targetSqrtUni),
            1 << 96
        );
        uint256 uniTradeableX = sqrtProduct > 0
            ? FullMath.mulDiv(uint256(uniL), deltaSqrtUni, sqrtProduct)
            : 0;

        // Take minimum of the two (bottleneck)
        tradeSize = pcsTradeableY < uniTradeableX
            ? pcsTradeableY
            : uniTradeableX;

        // Apply safety factor (30% of theoretical max)
        tradeSize = (tradeSize * SAFETY_FACTOR) / 10000;

        // Clamp to bounds
        if (tradeSize < MIN_TRADE) tradeSize = MIN_TRADE;
        if (tradeSize > MAX_TRADE) tradeSize = MAX_TRADE;
    }

    // ============ KEEPER PROFIT ============

    /// @notice Check if arbitrage is profitable
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        (uint256 tradeSize, bool isForward) = estimateTradeSize();

        if (tradeSize == 0) return (false, 0);

        uint256 pcsPrice = getPcsPrice();
        uint256 uniPrice = getUniPrice();

        // Fee buffer: PCS 0.05% + Uni 0.05% = 0.1%, plus margin
        uint256 feeBuffer = (pcsPrice * 15) / 10000; // 15bps total

        uint256 spread;
        if (isForward && pcsPrice + feeBuffer < uniPrice) {
            spread = uniPrice - pcsPrice - feeBuffer;
        } else if (!isForward && uniPrice + feeBuffer < pcsPrice) {
            spread = pcsPrice - uniPrice - feeBuffer;
        } else {
            return (false, 0);
        }

        // Expected profit = spread × tradeSize / 1e18
        expectedProfit = FullMath.mulDiv(spread, tradeSize, 1e18);

        // Profitable if > 0.01 AUSD (1e16 in 1e18 format, ~$0.01)
        profitable = expectedProfit > 1e16;
    }

    // ============ EXECUTE (AUTONOMOUS) ============

    /// @notice Execute arbitrage - fully autonomous, calculates own trade size
    function execute() external returns (bool) {
        (uint256 tradeSize, bool isForward) = estimateTradeSize();

        if (tradeSize < MIN_TRADE) return false;

        uint256 pcsPrice = getPcsPrice();
        uint256 uniPrice = getUniPrice();
        uint256 feeBuffer = (pcsPrice * 10) / 10000; // 10bps

        if (isForward && pcsPrice + feeBuffer < uniPrice) {
            _executeForward(tradeSize, pcsPrice, uniPrice);
            return true;
        } else if (!isForward && uniPrice + feeBuffer < pcsPrice) {
            _executeReverse(tradeSize, uniPrice, pcsPrice);
            return true;
        }

        return false;
    }

    // ============ FORWARD: PCS → UNI ============

    function _executeForward(
        uint256 amountMon,
        uint256 pcsPrice,
        uint256 uniPrice
    ) internal {
        // Price limit: stop if pcsPrice rises too close to uniPrice
        // AUSD/WMON pool is INVERSE: higher price = lower sqrtPrice
        uint256 safeBid = (uniPrice * 10020) / 10000;
        uint160 pcsLimit = _priceToSqrtPricePcs(safeBid);

        PCS_POOL.swap(
            address(this),
            true, // AUSD → WMON
            -int256(amountMon),
            pcsLimit,
            abi.encode(true, amountMon, uniPrice)
        );
    }

    // ============ REVERSE: UNI → PCS ============

    function _executeReverse(
        uint256 amountMon,
        uint256 uniPrice,
        uint256 pcsPrice
    ) internal {
        // Price limit for Uni: stop if uniPrice rises too close to pcsPrice
        // MON/AUSD pool is DIRECT: higher price = higher sqrtPrice
        uint256 safeAsk = (pcsPrice * 9980) / 10000;
        uint160 uniLimit = _priceToSqrtPriceUni(safeAsk);

        PM.unlock(abi.encode(false, amountMon, pcsPrice, uniLimit));
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        if (msg.sender != address(PCS_POOL)) revert Unauthorized();

        (bool isForward, , uint256 uniPrice) = abi.decode(
            data,
            (bool, uint256, uint256)
        );

        if (isForward) {
            uint256 wmonReceived = uint256(-amount1Delta);
            uint256 ausdOwed = uint256(amount0Delta);

            WMON.withdraw(wmonReceived);

            uint160 uniLimit = _priceToSqrtPriceUni((uniPrice * 9993) / 10000);
            PM.unlock(abi.encode(true, wmonReceived, ausdOwed, uniLimit));
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
            uint256 amountAusdOrPcsPrice,
            uint160 sqrtLimit
        ) = abi.decode(data, (bool, uint256, uint256, uint160));

        if (isForward) {
            uint256 ausdOwed = amountAusdOrPcsPrice;

            PoolKey memory key = getPoolKey();
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(amountMon),
                    sqrtPriceLimitX96: sqrtLimit
                }),
                ""
            );

            int128 monSpent = delta.amount0();
            int128 ausdReceived = -delta.amount1();

            if (monSpent > 0) {
                PM.settle{value: uint256(uint128(monSpent))}();
            }

            if (ausdReceived > 0) {
                PM.take(
                    AUSD_CURRENCY,
                    address(this),
                    uint256(uint128(ausdReceived))
                );
            }

            uint256 ausdBal = AUSD.balanceOf(address(this));
            if (ausdBal < ausdOwed) revert InsufficientOutput();
            AUSD.transfer(address(PCS_POOL), ausdOwed);

            uint256 profit = AUSD.balanceOf(address(this));
            if (profit > 0) {
                AUSD.transfer(owner, profit);
            }
        } else {
            uint256 pcsPrice = amountAusdOrPcsPrice;

            PoolKey memory key = getPoolKey();
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amountMon),
                    sqrtPriceLimitX96: sqrtLimit
                }),
                ""
            );

            int128 monReceived = -delta.amount0();
            int128 ausdDebt = delta.amount1();

            if (monReceived > 0) {
                PM.take(
                    MON_CURRENCY,
                    address(this),
                    uint256(uint128(monReceived))
                );
            }

            uint256 monBal = address(this).balance;
            WMON.deposit{value: monBal}();

            uint160 pcsLimit = _priceToSqrtPricePcs((pcsPrice * 9993) / 10000);

            PCS_POOL.swap(
                address(this),
                false,
                int256(WMON.balanceOf(address(this))),
                pcsLimit,
                abi.encode(false)
            );

            uint256 ausdBal = AUSD.balanceOf(address(this));
            if (int256(ausdBal) < ausdDebt) revert InsufficientOutput();

            AUSD.transfer(address(PM), uint256(uint128(ausdDebt)));
            PM.settle();

            uint256 profit = AUSD.balanceOf(address(this));
            if (profit > 0) {
                AUSD.transfer(owner, profit);
            }
        }

        return "";
    }

    // ============ SQRT PRICE CONVERSIONS ============

    function _priceToSqrtPricePcs(
        uint256 priceAusdPerMon
    ) internal pure returns (uint160) {
        uint256 inversePrice = (PRICE_SCALE_FACTOR * BASE_MULTIPLIER) /
            priceAusdPerMon;
        uint256 sqrtInverse = FixedPointMathLib.sqrt(inversePrice);
        return uint160(FullMath.mulDiv(sqrtInverse, 1 << 96, 1e9));
    }

    function _priceToSqrtPriceUni(
        uint256 priceAusdPerMon
    ) internal view returns (uint160) {
        uint256 root = FixedPointMathLib.sqrt(priceAusdPerMon);
        return uint160(FullMath.mulDiv(root, 1 << 96, SQRT_PRICE_SCALE));
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

        uint256 ausdBal = AUSD.balanceOf(address(this));
        if (ausdBal > 0) {
            AUSD.transfer(owner, ausdBal);
        }
    }
}
