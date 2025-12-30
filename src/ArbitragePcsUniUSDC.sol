// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
/// @dev Simplified: uses 80% of min liquidity, no sqrtPriceLimit (uses MIN/MAX)
///      PCS Pool: token0=WMON, token1=USDC (sqrtPrice = sqrt(USDC/WMON)) - DIRECT
///      Uni Pool: currency0=MON, currency1=USDC (sqrtPrice = sqrt(USDC/MON)) - DIRECT
contract ArbitragePcsUniUSDC is IPancakeV3SwapCallback, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ============ ERRORS ============
    error Unauthorized();
    error InsufficientOutput();

    // ============ CONSTANTS ============
    uint256 constant MIN_TRADE = 1e18; // 1 MON minimum
    uint256 constant MAX_TRADE = 20000e18; // 20k MON maximum
    uint256 constant SIZING_PCT = 8000; // 80% of calculated tradeable

    // Price limits - effectively "no limit"
    uint160 constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342 - 1;

    // ============ IMMUTABLES ============
    IPancakeV3Pool public immutable PCS_POOL;
    IPoolManager public immutable PM;
    IWMON public immutable WMON;
    IERC20 public immutable USDC;
    address public immutable owner;

    Currency constant MON_CURRENCY = Currency.wrap(address(0));
    Currency public immutable USDC_CURRENCY;

    uint256 constant PRICE_SCALE_FACTOR = 1e30;

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
    }

    receive() external payable {}

    // ============ POOL KEY ============

    function getPoolKey() public view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON_CURRENCY,
                currency1: USDC_CURRENCY,
                fee: 500,
                tickSpacing: 10, // MON/USDC uses tickSpacing=10
                hooks: IHooks(address(0))
            });
    }

    // ============ PRICE QUERIES ============

    /// @notice Get PCS price (USDC per MON in 1e18)
    function getPcsPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();
        // PCS: token0=WMON, token1=USDC, sqrtPrice = sqrt(USDC/WMON)
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                PRICE_SCALE_FACTOR,
                1 << 192
            );
    }

    /// @notice Get Uni V4 price (USDC per MON in 1e18)
    function getUniPrice() public view returns (uint256) {
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        // Uni: currency0=MON, currency1=USDC, sqrtPrice = sqrt(USDC/MON)
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                PRICE_SCALE_FACTOR,
                1 << 192
            );
    }

    // ============ TRADE SIZE ESTIMATION ============

    /// @notice Calculate trade size: 80% of min(PCS liquidity, Uni liquidity)
    function estimateTradeSize()
        public
        view
        returns (uint256 tradeSize, bool isForward)
    {
        // Get PCS state
        (uint160 pcsSqrt, , , , , , ) = PCS_POOL.slot0();
        uint128 pcsL = PCS_POOL.liquidity();

        // Get Uni state
        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 uniSqrt, , , ) = PM.getSlot0(id);
        uint128 uniL = PM.getLiquidity(id);

        // Convert to prices (both DIRECT: higher sqrtPrice = higher price)
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

        // Determine direction
        if (pcsPrice < uniPrice) {
            isForward = true; // Buy on PCS (cheap), sell on Uni (expensive)
        } else if (uniPrice < pcsPrice) {
            isForward = false; // Buy on Uni (cheap), sell on PCS (expensive)
        } else {
            return (0, false); // No opportunity
        }

        // Target price is midpoint
        uint256 targetPrice = (pcsPrice + uniPrice) / 2;

        // Calculate tradeable amounts using ΔY = L × |√Pb - √Pa|
        uint160 targetSqrtPcs = _priceToSqrtPrice(targetPrice);
        uint160 targetSqrtUni = _priceToSqrtPrice(targetPrice);

        uint256 deltaSqrtPcs = pcsSqrt > targetSqrtPcs
            ? uint256(pcsSqrt) - uint256(targetSqrtPcs)
            : uint256(targetSqrtPcs) - uint256(pcsSqrt);
        uint256 pcsTradeable = FullMath.mulDiv(
            uint256(pcsL),
            deltaSqrtPcs,
            1 << 96
        );

        uint256 deltaSqrtUni = uniSqrt > targetSqrtUni
            ? uint256(uniSqrt) - uint256(targetSqrtUni)
            : uint256(targetSqrtUni) - uint256(uniSqrt);
        uint256 uniTradeable = FullMath.mulDiv(
            uint256(uniL),
            deltaSqrtUni,
            1 << 96
        );

        // Take minimum and apply 80% sizing
        tradeSize = pcsTradeable < uniTradeable ? pcsTradeable : uniTradeable;
        tradeSize = (tradeSize * SIZING_PCT) / 10000;

        // Clamp
        if (tradeSize < MIN_TRADE) tradeSize = 0;
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
        profitable = expectedProfit > 5e17; // 0.5 USDC min profit
    }

    // ============ EXECUTE ============

    function execute() external returns (bool) {
        (uint256 tradeSize, bool isForward) = estimateTradeSize();
        if (tradeSize < MIN_TRADE) return false;

        uint256 pcsPrice = getPcsPrice();
        uint256 uniPrice = getUniPrice();
        uint256 feeBuffer = (pcsPrice * 10) / 10000;

        if (isForward && pcsPrice + feeBuffer < uniPrice) {
            _executeForward(tradeSize);
            return true;
        } else if (!isForward && uniPrice + feeBuffer < pcsPrice) {
            _executeReverse(tradeSize);
            return true;
        }

        return false;
    }

    // ============ FORWARD: PCS → UNI ============
    // Buy WMON on PCS (cheap), unwrap, sell MON on Uni (expensive)

    function _executeForward(uint256 amountMon) internal {
        // PCS: zeroForOne=false (buy token0=WMON with token1=USDC)
        // exactOutput: we want amountMon WMON out
        PCS_POOL.swap(
            address(this),
            false,
            -int256(amountMon), // Negative = exactOutput
            MAX_SQRT_RATIO, // No limit for zeroForOne=false
            abi.encode(true, amountMon)
        );
    }

    // ============ REVERSE: UNI → PCS ============
    // Buy MON on Uni (cheap), wrap, sell WMON on PCS (expensive)

    function _executeReverse(uint256 amountMon) internal {
        PM.unlock(abi.encode(false, amountMon));
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        if (msg.sender != address(PCS_POOL)) revert Unauthorized();

        (bool isForward, ) = abi.decode(data, (bool, uint256));

        if (isForward) {
            // Forward: we received WMON (amount0<0), owe USDC (amount1>0)
            uint256 wmonReceived = uint256(-amount0Delta);
            uint256 usdcOwed = uint256(amount1Delta);

            // Unwrap WMON to MON
            WMON.withdraw(wmonReceived);

            // Sell MON on Uni for USDC
            PM.unlock(abi.encode(true, wmonReceived, usdcOwed));
        } else {
            // Reverse callback: we sold WMON (amount0>0), received USDC (amount1<0)
            uint256 wmonOwed = uint256(amount0Delta);

            // Pay WMON to PCS
            WMON.transfer(address(PCS_POOL), wmonOwed);

            // Send profit
            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        }
    }

    // ============ UNI V4 CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(PM)) revert Unauthorized();

        bool isForward = abi.decode(data, (bool));

        if (isForward) {
            // Forward: sell MON for USDC, pay back PCS
            (, uint256 monAmount, uint256 usdcOwed) = abi.decode(
                data,
                (bool, uint256, uint256)
            );

            PoolKey memory key = getPoolKey();

            // Swap MON for USDC (zeroForOne=true, exactInput)
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(monAmount),
                    sqrtPriceLimitX96: MIN_SQRT_RATIO
                }),
                ""
            );

            // Settle: pay MON
            uint128 monSpent = uint128(delta.amount0());
            if (monSpent > 0) {
                PM.settle{value: monSpent}();
            }

            // Take: receive USDC
            uint128 usdcReceived = uint128(-delta.amount1());
            if (usdcReceived > 0) {
                PM.take(USDC_CURRENCY, address(this), usdcReceived);
            }

            // Pay back PCS
            if (usdcReceived < usdcOwed) revert InsufficientOutput();
            USDC.transfer(address(PCS_POOL), usdcOwed);

            // Send profit
            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        } else {
            // Reverse: buy MON with USDC, then sell on PCS
            (, uint256 monAmount) = abi.decode(data, (bool, uint256));

            PoolKey memory key = getPoolKey();

            // Swap USDC for MON (zeroForOne=false, exactOutput)
            BalanceDelta delta = PM.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(monAmount),
                    sqrtPriceLimitX96: MAX_SQRT_RATIO
                }),
                ""
            );

            // Take: receive MON
            uint128 monReceived = uint128(-delta.amount0());
            if (monReceived > 0) {
                PM.take(MON_CURRENCY, address(this), monReceived);
            }

            // Wrap MON to WMON
            WMON.deposit{value: address(this).balance}();

            // Swap WMON for USDC on PCS (zeroForOne=true: token0→token1)
            PCS_POOL.swap(
                address(this),
                true,
                int256(WMON.balanceOf(address(this))), // exactInput
                MIN_SQRT_RATIO,
                abi.encode(false, uint256(0))
            );

            // Settle USDC debt to Uni
            uint128 usdcDebt = uint128(delta.amount1());
            uint256 usdcBal = USDC.balanceOf(address(this));
            if (usdcBal < usdcDebt) revert InsufficientOutput();

            USDC.transfer(address(PM), usdcDebt);
            PM.settle();

            // Send profit
            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) {
                USDC.transfer(owner, profit);
            }
        }

        return "";
    }

    // ============ SQRT PRICE CONVERSION ============

    function _priceToSqrtPrice(
        uint256 priceUsdcPerMon
    ) internal pure returns (uint160) {
        // Both pools DIRECT: sqrtPrice = sqrt(USDC/MON)
        uint256 root = FixedPointMathLib.sqrt(priceUsdcPerMon);
        return uint160(FullMath.mulDiv(root, 1 << 96, 1e9));
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");
        uint256 usdcBal = USDC.balanceOf(address(this));
        uint256 wmonBal = WMON.balanceOf(address(this));
        if (usdcBal > 0) USDC.transfer(owner, usdcBal);
        if (wmonBal > 0) WMON.transfer(owner, wmonBal);
        if (address(this).balance > 0) {
            payable(owner).call{value: address(this).balance}("");
        }
    }
}
