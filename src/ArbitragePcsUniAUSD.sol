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
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {
    IPancakeV3Pool,
    IPancakeV3SwapCallback
} from "./interfaces/IPancakeV3Pool.sol";
import {IWMON} from "./interfaces/IWMON.sol";

/// @title ArbitragePcsUniAUSD
/// @notice Arbitrage between PancakeSwap V3 AUSD/WMON and Uniswap V4 MON/AUSD pools
/// @dev Simplified: uses 80% of min liquidity, no sqrtPriceLimit (uses MIN/MAX)
contract ArbitragePcsUniAUSD is IPancakeV3SwapCallback, IUnlockCallback {
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
    IERC20 public immutable AUSD;
    address public immutable owner;

    Currency constant MON_CURRENCY = Currency.wrap(address(0));
    Currency public immutable AUSD_CURRENCY;

    uint256 constant PRICE_SCALE_FACTOR = 1e30;

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
        return
            FullMath.mulDiv(
                PRICE_SCALE_FACTOR,
                1 << 192,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96)
            );
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

    // ============ TRADE SIZE ESTIMATION ============

    /// @notice Calculate trade size: 80% of min(PCS liquidity, Uni liquidity)
    function estimateTradeSize()
        public
        view
        returns (uint256 tradeSize, bool isForward)
    {
        // Get prices
        (uint160 pcsSqrt, , , , , , ) = PCS_POOL.slot0();
        uint128 pcsL = PCS_POOL.liquidity();

        PoolKey memory key = getPoolKey();
        PoolId id = key.toId();
        (uint160 uniSqrt, , , ) = PM.getSlot0(id);
        uint128 uniL = PM.getLiquidity(id);

        // Convert to prices
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

        // Calculate PCS tradeable using ΔY = L × |√Pb - √Pa|
        uint160 targetSqrtPcs = _priceToSqrtPricePcs(targetPrice);
        uint256 deltaSqrtPcs = pcsSqrt > targetSqrtPcs
            ? uint256(pcsSqrt) - uint256(targetSqrtPcs)
            : uint256(targetSqrtPcs) - uint256(pcsSqrt);
        uint256 pcsTradeable = FullMath.mulDiv(
            uint256(pcsL),
            deltaSqrtPcs,
            1 << 96
        );

        // Calculate Uni tradeable using ΔX = L × (√Pb - √Pa) / (√Pa × √Pb)
        uint160 targetSqrtUni = _priceToSqrtPriceUni(targetPrice);
        uint256 deltaSqrtUni = uniSqrt > targetSqrtUni
            ? uint256(uniSqrt) - uint256(targetSqrtUni)
            : uint256(targetSqrtUni) - uint256(uniSqrt);
        uint256 sqrtProduct = FullMath.mulDiv(
            uint256(uniSqrt),
            uint256(targetSqrtUni),
            1 << 96
        );
        uint256 uniTradeable = sqrtProduct > 0
            ? FullMath.mulDiv(uint256(uniL), deltaSqrtUni, sqrtProduct)
            : 0;

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
        profitable = expectedProfit > 5e17; // 0.5 AUSD min profit
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
        // Step 1: Swap on PCS - buy WMON with AUSD
        // zeroForOne=true: sell token0(AUSD) for token1(WMON)
        // exactOutput: we want amountMon WMON out
        PCS_POOL.swap(
            address(this),
            true,
            -int256(amountMon), // Negative = exactOutput
            MIN_SQRT_RATIO, // No limit - just execute
            abi.encode(true, amountMon)
        );
    }

    // ============ REVERSE: UNI → PCS ============
    // Buy MON on Uni (cheap), wrap, sell WMON on PCS (expensive)

    function _executeReverse(uint256 amountMon) internal {
        // Step 1: Unlock Uni to buy MON
        PM.unlock(abi.encode(false, amountMon));
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        if (msg.sender != address(PCS_POOL)) revert Unauthorized();

        (bool isForward, uint256 amountMon) = abi.decode(data, (bool, uint256));

        if (isForward) {
            // Forward: we received WMON, owe AUSD to PCS
            uint256 wmonReceived = uint256(-amount1Delta);
            uint256 ausdOwed = uint256(amount0Delta);

            // Unwrap WMON to MON
            WMON.withdraw(wmonReceived);

            // Sell MON on Uni for AUSD
            PM.unlock(abi.encode(true, wmonReceived, ausdOwed));
        } else {
            // Reverse callback: we sold WMON, received AUSD
            uint256 ausdReceived = uint256(-amount0Delta);
            uint256 wmonOwed = uint256(amount1Delta);

            // Pay WMON to PCS
            WMON.transfer(address(PCS_POOL), wmonOwed);

            // Send profit
            uint256 profit = AUSD.balanceOf(address(this));
            if (profit > 0) {
                AUSD.transfer(owner, profit);
            }
        }
    }

    // ============ UNI V4 CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(PM)) revert Unauthorized();

        // Decode first byte to determine forward vs reverse
        bool isForward = abi.decode(data, (bool));

        if (isForward) {
            // Forward: sell MON for AUSD, pay back PCS
            (, uint256 monAmount, uint256 ausdOwed) = abi.decode(
                data,
                (bool, uint256, uint256)
            );

            PoolKey memory key = getPoolKey();

            // Swap MON for AUSD (zeroForOne=true, exactInput)
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

            // Take: receive AUSD
            uint128 ausdReceived = uint128(-delta.amount1());
            if (ausdReceived > 0) {
                PM.take(AUSD_CURRENCY, address(this), ausdReceived);
            }

            // Pay back PCS
            if (ausdReceived < ausdOwed) revert InsufficientOutput();
            AUSD.transfer(address(PCS_POOL), ausdOwed);

            // Send profit
            uint256 profit = AUSD.balanceOf(address(this));
            if (profit > 0) {
                AUSD.transfer(owner, profit);
            }
        } else {
            // Reverse: buy MON with AUSD, then sell on PCS
            (, uint256 monAmount) = abi.decode(data, (bool, uint256));

            PoolKey memory key = getPoolKey();

            // Swap AUSD for MON (zeroForOne=false, exactOutput)
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

            // Swap WMON for AUSD on PCS (zeroForOne=false: token1→token0)
            PCS_POOL.swap(
                address(this),
                false,
                int256(WMON.balanceOf(address(this))), // exactInput
                MAX_SQRT_RATIO,
                abi.encode(false, uint256(0))
            );

            // Now in PCS callback, we pay AUSD debt to Uni
            // Actually we need to settle Uni here
            uint128 ausdDebt = uint128(delta.amount1());
            uint256 ausdBal = AUSD.balanceOf(address(this));
            if (ausdBal < ausdDebt) revert InsufficientOutput();

            AUSD.transfer(address(PM), ausdDebt);
            PM.settle();

            // Send profit
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
        // PCS: sqrtPrice = sqrt(WMON/AUSD) = sqrt(1/price)
        uint256 inversePrice = (PRICE_SCALE_FACTOR * 1e18) / priceAusdPerMon;
        uint256 sqrtInverse = FixedPointMathLib.sqrt(inversePrice);
        return uint160(FullMath.mulDiv(sqrtInverse, 1 << 96, 1e9));
    }

    function _priceToSqrtPriceUni(
        uint256 priceAusdPerMon
    ) internal pure returns (uint160) {
        // Uni: sqrtPrice = sqrt(AUSD/MON) = sqrt(price)
        uint256 root = FixedPointMathLib.sqrt(priceAusdPerMon);
        return uint160(FullMath.mulDiv(root, 1 << 96, 1e9));
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");
        uint256 ausdBal = AUSD.balanceOf(address(this));
        uint256 wmonBal = WMON.balanceOf(address(this));
        if (ausdBal > 0) AUSD.transfer(owner, ausdBal);
        if (wmonBal > 0) WMON.transfer(owner, wmonBal);
        if (address(this).balance > 0) {
            payable(owner).call{value: address(this).balance}("");
        }
    }
}
