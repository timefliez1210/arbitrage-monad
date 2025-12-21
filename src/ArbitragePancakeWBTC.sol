// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
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

/// @title ArbitragePancakeWBTC
/// @notice Arbitrage between UniV4 MON/WBTC and PCS WBTC/WMON
/// @dev Architecture:
///      - UniV4 as flash source via unlock()
///      - PCS WBTC/WMON as bottleneck for liquidity estimation
///      - Forward: MON swap on UniV4 -> WBTC -> WMON on PCS -> unwrap -> settle more MON
///      - Reverse: MON swap on UniV4 via PCS path
///      - CurrencyNotSettled is natural guard for unprofitable trades
contract ArbitragePancakeWBTC is IUnlockCallback, IPancakeV3SwapCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ============ CONSTANTS ============
    IPoolManager public constant PM =
        IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);
    IPancakeV3Pool public constant PCS_POOL =
        IPancakeV3Pool(0x0944526D2727B532653E6Ca6c4D980461E170a09);
    IWMON public constant WMON =
        IWMON(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);
    IERC20 public constant WBTC =
        IERC20(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c);

    Currency constant MON = Currency.wrap(address(0));
    Currency constant WBTC_CURRENCY =
        Currency.wrap(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c);

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 1;

    // Decimals
    uint8 constant MON_DECIMALS = 18;
    uint8 constant WBTC_DECIMALS = 8;

    // Trade sizing
    uint256 constant LIQUIDITY_FRACTION = 4000; // 40% of estimated
    uint256 constant MIN_TRADE_SIZE = 100 ether; // 100 MON min
    uint256 constant MAX_TRADE_SIZE = 50000 ether; // 50k MON max

    // Owner
    address public immutable owner;

    // ============ CONSTRUCTOR ============
    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    // ============ POOL KEY ============

    function getPoolKeyMonWbtc() public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON,
                currency1: WBTC_CURRENCY,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
    }

    // ============ PRICE HELPERS ============

    function getSqrtPriceUniV4() public view returns (uint160) {
        PoolId id = getPoolKeyMonWbtc().toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        return sqrtPriceX96;
    }

    function getSqrtPricePCS() public view returns (uint160) {
        (uint160 sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();
        return sqrtPriceX96;
    }

    /// @notice Get UniV4 price (WBTC per MON in 1e18)
    function getUniswapPrice() public view returns (uint256) {
        uint160 sqrtPriceX96 = getSqrtPriceUniV4();
        if (sqrtPriceX96 == 0) return 0;
        // price = sqrtPriceX96^2 * 10^(18+18-8) / 2^192
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                1e28,
                1 << 192
            );
    }

    /// @notice Get PCS price (WBTC per MON in 1e18)
    /// @dev PCS pool: token0=WBTC(8), token1=WMON(18)
    ///      sqrtPrice = sqrt(WMON/WBTC), we want WBTC/WMON
    function getPancakePrice() public view returns (uint256) {
        uint160 sqrtPriceX96 = getSqrtPricePCS();
        if (sqrtPriceX96 == 0) return 0;
        // WBTC/WMON = 1e28 * 2^192 / sqrtPriceX96^2
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        return FullMath.mulDiv(1e28, 1 << 192, sqrtPrice * sqrtPrice);
    }

    // ============ LIQUIDITY ESTIMATION ============

    /// @notice Estimate trade size based on min of UniV4 and PCS pool liquidity
    /// @dev Queries both pools and uses the lower liquidity as bottleneck
    function estimateTradeSize() public view returns (uint256 tradeSize) {
        uint256 uniPrice = getUniswapPrice(); // WBTC per MON in 1e18
        if (uniPrice == 0) return MIN_TRADE_SIZE;

        // Get UniV4 MON/WBTC pool liquidity
        PoolId poolId = getPoolKeyMonWbtc().toId();
        uint128 uniLiquidity = PM.getLiquidity(poolId);

        // Get PCS WBTC/WMON pool liquidity
        uint128 pcsLiquidity = PCS_POOL.liquidity();

        // Use minimum of both as bottleneck
        uint128 bottleneckLiquidity = uniLiquidity < pcsLiquidity
            ? uniLiquidity
            : pcsLiquidity;

        if (bottleneckLiquidity == 0) {
            return MIN_TRADE_SIZE;
        }

        // Approximate tradeable WBTC from liquidity
        // In Uniswap V3/V4: liquidity L relates to amounts via deltaX ≈ L / 1e6
        // This is conservative and depends on tick range
        uint256 tradeableWbtc = uint256(bottleneckLiquidity) / 1e6;

        // Convert WBTC to MON: MON = WBTC * 1e18 / priceWbtcPerMon
        // tradeableWbtc is in 1e8 (WBTC decimals), need to scale to 1e18
        uint256 tradeableMon = FullMath.mulDiv(
            tradeableWbtc * 1e10, // Scale WBTC(8) to 18 decimals
            1e18,
            uniPrice
        );

        // Take 40% of tradeable amount
        tradeSize = (tradeableMon * LIQUIDITY_FRACTION) / 10000;

        // Clamp to bounds
        if (tradeSize < MIN_TRADE_SIZE) tradeSize = MIN_TRADE_SIZE;
        if (tradeSize > MAX_TRADE_SIZE) tradeSize = MAX_TRADE_SIZE;
    }

    // ============ KEEPER PROFIT ============

    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        uint256 uniPrice = getUniswapPrice();
        uint256 pcsPrice = getPancakePrice();

        if (uniPrice == 0 || pcsPrice == 0) return (false, 0);

        // Total fees: Uni 5bps + PCS 5bps = 10bps
        uint256 fee = (uniPrice * 12) / 10000; // 12bps for safety

        // Forward: Uni cheap (low WBTC/MON) → buy WBTC on Uni, sell on PCS
        if (uniPrice + fee < pcsPrice) {
            uint256 spread = pcsPrice - uniPrice - fee;
            uint256 tradeSize = estimateTradeSize();
            expectedProfit = FullMath.mulDiv(tradeSize, spread, pcsPrice);
            if (expectedProfit > 0.5 ether) profitable = true;
        }
        // Reverse: PCS cheap → buy WBTC on PCS, sell on Uni
        else if (pcsPrice + fee < uniPrice) {
            uint256 spread = uniPrice - pcsPrice - fee;
            uint256 tradeSize = estimateTradeSize();
            expectedProfit = FullMath.mulDiv(tradeSize, spread, uniPrice);
            if (expectedProfit > 0.5 ether) profitable = true;
        }
    }

    // ============ EXECUTE ============

    function execute() external returns (bool) {
        uint256 uniPrice = getUniswapPrice();
        uint256 pcsPrice = getPancakePrice();

        if (uniPrice == 0 || pcsPrice == 0) return false;

        uint256 fee = (uniPrice * 12) / 10000;
        uint256 tradeSize = estimateTradeSize();

        bool isForward;
        if (uniPrice + fee < pcsPrice) {
            isForward = true;
        } else if (pcsPrice + fee < uniPrice) {
            isForward = false;
        } else {
            return false;
        }

        uint160 sqrtPriceUni = getSqrtPriceUniV4();
        bytes memory data = abi.encode(isForward, tradeSize, sqrtPriceUni);
        PM.unlock(data);

        return true;
    }

    // ============ UNIV4 UNLOCK CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(PM), "Only PM");

        (bool isForward, uint256 tradeSize, uint160 sqrtPriceUni) = abi.decode(
            data,
            (bool, uint256, uint160)
        );

        if (isForward) {
            _executeForward(tradeSize, sqrtPriceUni);
        } else {
            _executeReverse(tradeSize, sqrtPriceUni);
        }

        return "";
    }

    /// @notice Forward: MON → WBTC (UniV4) → WMON (PCS) → MON
    /// @dev Uni cheap, PCS dear. exactOutput WBTC, swap on PCS, settle MON
    function _executeForward(uint256 monAmount, uint160 sqrtPriceUni) internal {
        // Calculate expected WBTC from monAmount at current price
        // For simplicity, use a conservative estimate
        uint256 uniPrice = getUniswapPrice(); // WBTC per MON in 1e18
        uint256 wbtcExpected = FullMath.mulDiv(monAmount, uniPrice, 1e18);
        // Scale from 1e18 to WBTC decimals (1e8)
        wbtcExpected = wbtcExpected / 1e10;
        // Apply 0.5% slippage buffer
        wbtcExpected = (wbtcExpected * 995) / 1000;

        if (wbtcExpected == 0) return;

        // SWAP 1: MON → WBTC on UniV4 (exactOutput WBTC)
        // zeroForOne=true, negative amountSpecified = exactOutput
        uint160 sqrtLimit = uint160(
            FullMath.mulDiv(uint256(sqrtPriceUni), 997, 1000)
        );
        if (sqrtLimit <= TickMath.MIN_SQRT_PRICE)
            sqrtLimit = TickMath.MIN_SQRT_PRICE + 1;

        PoolKey memory key = getPoolKeyMonWbtc();
        BalanceDelta delta = PM.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(wbtcExpected), // negative = exactOutput WBTC
                sqrtPriceLimitX96: sqrtLimit
            }),
            ""
        );

        // For zeroForOne=true exactOutput:
        // delta.amount0() = negative (we owe MON)
        // delta.amount1() = positive (we receive exactly wbtcExpected WBTC)
        require(delta.amount1() > 0, "No WBTC received");
        uint256 wbtcReceived = uint256(int256(delta.amount1()));
        uint256 monOwed = uint256(-int256(delta.amount0()));

        // Take WBTC from PM
        PM.take(WBTC_CURRENCY, address(this), wbtcReceived);

        // SWAP 2: WBTC → WMON on PCS (exactInput)
        // zeroForOne=true means WBTC(token0) → WMON(token1)
        WBTC.approve(address(PCS_POOL), wbtcReceived);
        PCS_POOL.swap(
            address(this),
            true, // WBTC -> WMON
            int256(wbtcReceived), // exactInput
            TickMath.MIN_SQRT_PRICE + 1,
            abi.encode(true)
        );

        // After PCS callback, we have WMON - unwrap to MON
        uint256 wmonBal = WMON.balanceOf(address(this));
        WMON.withdraw(wmonBal);

        // Settle MON debt to UniV4
        PM.settle{value: monOwed}();

        // Profit = remaining MON
        uint256 profit = address(this).balance;
        if (profit > 0) {
            payable(owner).call{value: profit}("");
        }
    }

    /// @notice Reverse: PCS cheap, Uni dear
    /// @dev Flash WBTC->MON on Uni, wrap MON, PCS WMON->WBTC, settle WBTC debt, profit in WBTC
    function _executeReverse(uint256 monAmount, uint160 sqrtPriceUni) internal {
        // SWAP 1: WBTC → MON on UniV4 (exactOutput for MON, we'll owe WBTC)
        // zeroForOne=false (WBTC is currency1 → MON is currency0)
        uint160 sqrtLimit = uint160(
            FullMath.mulDiv(uint256(sqrtPriceUni), 1003, 1000)
        );
        if (sqrtLimit >= TickMath.MAX_SQRT_PRICE)
            sqrtLimit = TickMath.MAX_SQRT_PRICE - 1;

        PoolKey memory key = getPoolKeyMonWbtc();
        BalanceDelta delta = PM.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, // WBTC -> MON (currency1 -> currency0)
                amountSpecified: -int256(monAmount), // negative = exactOutput MON
                sqrtPriceLimitX96: sqrtLimit
            }),
            ""
        );

        // For zeroForOne=false exactOutput:
        // delta.amount0() = positive (we receive MON)
        // delta.amount1() = negative (we owe WBTC)
        require(delta.amount0() > 0, "No MON received");
        uint256 monReceived = uint256(int256(delta.amount0()));
        uint256 wbtcOwed = uint256(-int256(delta.amount1()));

        // Take MON from PM
        PM.take(MON, address(this), monReceived);

        // Wrap MON → WMON
        WMON.deposit{value: monReceived}();

        // SWAP 2: WMON → WBTC on PCS (exactInput)
        // zeroForOne=false means WMON(token1) → WBTC(token0)
        WMON.approve(address(PCS_POOL), monReceived);
        PCS_POOL.swap(
            address(this),
            false, // WMON -> WBTC
            int256(monReceived), // exactInput WMON
            TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(false) // isReverse
        );

        // After PCS callback, we have WBTC
        uint256 wbtcBal = WBTC.balanceOf(address(this));
        require(wbtcBal >= wbtcOwed, "Not enough WBTC");

        // Settle WBTC debt to UniV4
        PM.sync(WBTC_CURRENCY);
        WBTC.transfer(address(PM), wbtcOwed);
        PM.settle();

        // Profit = remaining WBTC
        uint256 profit = WBTC.balanceOf(address(this));
        if (profit > 0) {
            WBTC.transfer(owner, profit);
        }
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external {
        require(msg.sender == address(PCS_POOL), "Only PCS");

        // Pay the required token
        if (amount0Delta > 0) {
            // We owe WBTC
            WBTC.transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            // We owe WMON
            WMON.transfer(msg.sender, uint256(amount1Delta));
        }
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");
        if (address(this).balance > 0) {
            payable(owner).call{value: address(this).balance}("");
        }
        uint256 wbtcBal = WBTC.balanceOf(address(this));
        if (wbtcBal > 0) WBTC.transfer(owner, wbtcBal);
        uint256 wmonBal = WMON.balanceOf(address(this));
        if (wmonBal > 0) WMON.transfer(owner, wmonBal);
    }
}
