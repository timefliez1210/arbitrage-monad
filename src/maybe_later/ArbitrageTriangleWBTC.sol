//SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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

/// @title ArbitrageTriangleWBTC
/// @notice Triangular arbitrage across MON/WBTC, AUSD/WBTC, and MON/AUSD pools
/// @dev Uses V4 flash accounting with EXACT INPUT swaps
///
/// Pool Configuration (all fee=500, tickSpacing=1):
/// - MON/WBTC: currency0=MON(18), currency1=WBTC(8)
/// - AUSD/WBTC: currency0=AUSD(6), currency1=WBTC(8) <- BOTTLENECK (lowest liquidity)
/// - MON/AUSD: currency0=MON(18), currency1=AUSD(6)
///
/// Trade sizing: Query AUSD/WBTC liquidity, estimate max trade assuming even distribution
contract ArbitrageTriangleWBTC is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ============ CONSTANTS ============

    IPoolManager public constant PM =
        IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);

    // Token addresses
    address public constant WBTC_ADDRESS =
        0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address public constant AUSD_ADDRESS =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    // Currencies
    Currency constant MON = Currency.wrap(address(0));
    Currency constant WBTC = Currency.wrap(WBTC_ADDRESS);
    Currency constant AUSD = Currency.wrap(AUSD_ADDRESS);

    // Pool parameters
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 1;

    // Decimals
    uint8 constant MON_DECIMALS = 18;
    uint8 constant WBTC_DECIMALS = 8;
    uint8 constant AUSD_DECIMALS = 6;

    // Trade sizing parameters
    // Max % of bottleneck liquidity to use (40% = 4000 / 10000)
    uint256 constant LIQUIDITY_FRACTION = 4000; // 40%
    uint256 constant LIQUIDITY_DENOMINATOR = 10000;

    // Minimum trade size in MON (to cover gas)
    uint256 constant MIN_TRADE_SIZE = 1.5 ether; // 1.5 MON
    // Maximum trade size cap
    uint256 constant MAX_TRADE_SIZE = 100000 ether; // 100k MON

    // Owner for profit
    address public immutable owner;

    // ============ CONSTRUCTOR ============

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    // ============ POOL KEYS ============

    function getPoolKeyMonWbtc() public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON,
                currency1: WBTC,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
    }

    function getPoolKeyAusdWbtc() public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: AUSD,
                currency1: WBTC,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
    }

    function getPoolKeyMonAusd() public pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: MON,
                currency1: AUSD,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
    }

    // ============ PRICE HELPERS ============

    function getSqrtPrice(PoolKey memory key) internal view returns (uint160) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, , , ) = PM.getSlot0(id);
        return sqrtPriceX96;
    }

    /// @notice Convert sqrtPriceX96 to price with 1e18 precision
    function sqrtPriceToPrice(
        uint160 sqrtPriceX96,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 scaleFactor = 10 ** (18 + decimals0 - decimals1);
        return FullMath.mulDiv(sqrtPrice * sqrtPrice, scaleFactor, 1 << 192);
    }

    // ============ LIQUIDITY ESTIMATION ============

    /// @notice Get bottleneck pool liquidity and estimate max trade size
    /// @dev Queries AUSD/WBTC pool (lowest liquidity), converts to MON terms
    function estimateTradeSize() public view returns (uint256 tradeSize) {
        // Get AUSD/WBTC pool liquidity (this is in sqrt(AUSD * WBTC) units)
        PoolId bottleneckId = getPoolKeyAusdWbtc().toId();
        uint128 liquidity = PM.getLiquidity(bottleneckId);

        if (liquidity == 0) {
            return MIN_TRADE_SIZE;
        }

        // Get prices to convert liquidity to MON terms
        uint256 priceMonWbtc = sqrtPriceToPrice(
            getSqrtPrice(getPoolKeyMonWbtc()),
            MON_DECIMALS,
            WBTC_DECIMALS
        );
        uint256 priceAusdWbtc = sqrtPriceToPrice(
            getSqrtPrice(getPoolKeyAusdWbtc()),
            AUSD_DECIMALS,
            WBTC_DECIMALS
        );

        if (priceMonWbtc == 0 || priceAusdWbtc == 0) {
            return MIN_TRADE_SIZE;
        }

        // Approximate tradeable WBTC from liquidity
        // In Uniswap V3/V4, liquidity L relates to amounts via:
        // deltaX ≈ L * deltaPrice / price (very rough approximation)
        // For simplicity, assume we can trade ~L / 1e6 WBTC safely
        // This is conservative and depends on tick range
        uint256 tradeableWbtc = uint256(liquidity) / 1e6;

        // Convert WBTC to MON: MON = WBTC / priceMonWbtc * 1e18
        // priceMonWbtc = WBTC per MON, so MON = WBTC * 1e18 / priceMonWbtc
        uint256 tradeableMonFromWbtc = FullMath.mulDiv(
            tradeableWbtc * 1e10, // Scale WBTC(8) to 18 decimals
            1e18,
            priceMonWbtc
        );

        // Take fraction of tradeable amount
        tradeSize =
            (tradeableMonFromWbtc * LIQUIDITY_FRACTION) /
            LIQUIDITY_DENOMINATOR;

        // Clamp to bounds
        if (tradeSize < MIN_TRADE_SIZE) {
            tradeSize = MIN_TRADE_SIZE;
        }
        if (tradeSize > MAX_TRADE_SIZE) {
            tradeSize = MAX_TRADE_SIZE;
        }
    }

    // ============ KEEPER PROFIT CHECK ============

    /// @notice Lightweight profit check for off-chain keeper
    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        uint160 sqrtMonWbtc = getSqrtPrice(getPoolKeyMonWbtc());
        uint160 sqrtAusdWbtc = getSqrtPrice(getPoolKeyAusdWbtc());
        uint160 sqrtMonAusd = getSqrtPrice(getPoolKeyMonAusd());

        if (sqrtMonWbtc == 0 || sqrtAusdWbtc == 0 || sqrtMonAusd == 0) {
            return (false, 0);
        }

        uint256 priceMonWbtc = sqrtPriceToPrice(
            sqrtMonWbtc,
            MON_DECIMALS,
            WBTC_DECIMALS
        );
        uint256 priceAusdWbtc = sqrtPriceToPrice(
            sqrtAusdWbtc,
            AUSD_DECIMALS,
            WBTC_DECIMALS
        );
        uint256 priceMonAusd = sqrtPriceToPrice(
            sqrtMonAusd,
            MON_DECIMALS,
            AUSD_DECIMALS
        );

        // Total fees for 3 swaps: 3 * 0.05% = 0.15%
        // Plus slippage buffer: ~0.5% total = 50 bps
        uint256 totalFeeBps = 50;
        uint256 minOutput = (1e18 * (10000 + totalFeeBps)) / 10000;

        // Forward path: MON → WBTC → AUSD → MON
        if (priceMonWbtc > 0 && priceAusdWbtc > 0 && priceMonAusd > 0) {
            uint256 forwardOutput = FullMath.mulDiv(
                FullMath.mulDiv(1e18, priceMonWbtc, priceAusdWbtc),
                1e18,
                priceMonAusd
            );

            if (forwardOutput > minOutput) {
                uint256 tradeSize = estimateTradeSize();
                // Profit in MON = tradeSize * (forwardOutput - 1e18) / 1e18
                expectedProfit = FullMath.mulDiv(
                    tradeSize,
                    forwardOutput - 1e18,
                    1e18
                );
                return (true, expectedProfit);
            }
        }

        // Reverse path: MON → AUSD → WBTC → MON
        if (priceAusdWbtc > 0 && priceMonAusd > 0 && priceMonWbtc > 0) {
            uint256 reverseOutput = FullMath.mulDiv(
                FullMath.mulDiv(1e18, priceMonAusd, 1e18),
                priceAusdWbtc,
                priceMonWbtc
            );

            if (reverseOutput > minOutput) {
                uint256 tradeSize = estimateTradeSize();
                expectedProfit = FullMath.mulDiv(
                    tradeSize,
                    reverseOutput - 1e18,
                    1e18
                );
                return (true, expectedProfit);
            }
        }
    }

    // ============ EXECUTE ============

    function execute() external returns (bool) {
        uint160 sqrtMonWbtc = getSqrtPrice(getPoolKeyMonWbtc());
        uint160 sqrtAusdWbtc = getSqrtPrice(getPoolKeyAusdWbtc());
        uint160 sqrtMonAusd = getSqrtPrice(getPoolKeyMonAusd());

        if (sqrtMonWbtc == 0 || sqrtAusdWbtc == 0 || sqrtMonAusd == 0) {
            return false;
        }

        uint256 priceMonWbtc = sqrtPriceToPrice(
            sqrtMonWbtc,
            MON_DECIMALS,
            WBTC_DECIMALS
        );
        uint256 priceAusdWbtc = sqrtPriceToPrice(
            sqrtAusdWbtc,
            AUSD_DECIMALS,
            WBTC_DECIMALS
        );
        uint256 priceMonAusd = sqrtPriceToPrice(
            sqrtMonAusd,
            MON_DECIMALS,
            AUSD_DECIMALS
        );

        uint256 totalFeeBps = 50;
        uint256 minOutput = (1e18 * (10000 + totalFeeBps)) / 10000;

        bool isForward;

        // Check forward path
        uint256 forwardOutput = FullMath.mulDiv(
            FullMath.mulDiv(1e18, priceMonWbtc, priceAusdWbtc),
            1e18,
            priceMonAusd
        );
        if (forwardOutput > minOutput) {
            isForward = true;
        } else {
            // Check reverse path
            uint256 reverseOutput = FullMath.mulDiv(
                FullMath.mulDiv(1e18, priceMonAusd, 1e18),
                priceAusdWbtc,
                priceMonWbtc
            );
            if (reverseOutput > minOutput) {
                isForward = false;
            } else {
                return false;
            }
        }

        // Estimate optimal trade size based on bottleneck liquidity
        uint256 tradeSize = estimateTradeSize();

        // Pass current sqrtPrices for price limit calculation
        bytes memory data = abi.encode(
            isForward,
            tradeSize,
            sqrtMonWbtc,
            sqrtAusdWbtc,
            sqrtMonAusd
        );
        PM.unlock(data);

        return true;
    }

    // ============ UNLOCK CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(PM), "Only PM");

        (
            bool isForward,
            uint256 tradeSize,
            uint160 sqrtMonWbtc,
            uint160 sqrtAusdWbtc,
            uint160 sqrtMonAusd
        ) = abi.decode(data, (bool, uint256, uint160, uint160, uint160));

        if (isForward) {
            _executeForward(tradeSize, sqrtMonWbtc);
        } else {
            _executeReverse(tradeSize, sqrtMonAusd);
        }

        return "";
    }

    /// @notice Forward path: MON → WBTC → AUSD → MON
    /// @param sqrtMonWbtc Current sqrtPrice for price limit calculation
    function _executeForward(uint256 monAmount, uint160 sqrtMonWbtc) internal {
        // SWAP 1: MON → WBTC with calculated price limit
        // Apply 50bps buffer to protect against price movement
        // For zeroForOne=true, price decreases, so limit = current * sqrt(0.995)
        uint160 sqrtLimit = uint160(
            FullMath.mulDiv(uint256(sqrtMonWbtc), 997, 1000)
        );
        if (sqrtLimit <= TickMath.MIN_SQRT_PRICE) {
            sqrtLimit = TickMath.MIN_SQRT_PRICE + 1;
        }

        PoolKey memory keyMonWbtc = getPoolKeyMonWbtc();
        BalanceDelta delta1 = PM.swap(
            keyMonWbtc,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(monAmount),
                sqrtPriceLimitX96: sqrtLimit
            }),
            ""
        );
        require(delta1.amount1() > 0, "Swap1: no WBTC");
        uint256 wbtcReceived = uint256(int256(delta1.amount1()));

        // SWAP 2: WBTC → AUSD
        PoolKey memory keyAusdWbtc = getPoolKeyAusdWbtc();
        BalanceDelta delta2 = PM.swap(
            keyAusdWbtc,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(wbtcReceived),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        require(delta2.amount0() > 0, "Swap2: no AUSD");
        uint256 ausdReceived = uint256(int256(delta2.amount0()));

        // SWAP 3: AUSD → MON
        PoolKey memory keyMonAusd = getPoolKeyMonAusd();
        BalanceDelta delta3 = PM.swap(
            keyMonAusd,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(ausdReceived),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        require(delta3.amount0() > 0, "Swap3: no MON");
        uint256 monReceived = uint256(int256(delta3.amount0()));

        // Verify profit & settle
        require(monReceived > monAmount, "Not profitable");
        uint256 profit = monReceived - monAmount;

        PM.take(MON, address(this), profit);

        (bool sent, ) = payable(owner).call{value: address(this).balance}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Reverse path: MON → AUSD → WBTC → MON
    /// @param sqrtMonAusd Current sqrtPrice for price limit calculation
    function _executeReverse(uint256 monAmount, uint160 sqrtMonAusd) internal {
        // SWAP 1: MON → AUSD with calculated price limit
        // Apply 50bps buffer: limit = current * sqrt(0.995) ≈ current * 0.997
        uint160 sqrtLimit = uint160(
            FullMath.mulDiv(uint256(sqrtMonAusd), 997, 1000)
        );
        if (sqrtLimit <= TickMath.MIN_SQRT_PRICE) {
            sqrtLimit = TickMath.MIN_SQRT_PRICE + 1;
        }

        PoolKey memory keyMonAusd = getPoolKeyMonAusd();
        BalanceDelta delta1 = PM.swap(
            keyMonAusd,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(monAmount),
                sqrtPriceLimitX96: sqrtLimit
            }),
            ""
        );
        require(delta1.amount1() > 0, "Swap1: no AUSD");
        uint256 ausdReceived = uint256(int256(delta1.amount1()));

        // SWAP 2: AUSD → WBTC
        PoolKey memory keyAusdWbtc = getPoolKeyAusdWbtc();
        BalanceDelta delta2 = PM.swap(
            keyAusdWbtc,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ausdReceived),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        require(delta2.amount1() > 0, "Swap2: no WBTC");
        uint256 wbtcReceived = uint256(int256(delta2.amount1()));

        // SWAP 3: WBTC → MON
        PoolKey memory keyMonWbtc = getPoolKeyMonWbtc();
        BalanceDelta delta3 = PM.swap(
            keyMonWbtc,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(wbtcReceived),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        require(delta3.amount0() > 0, "Swap3: no MON");
        uint256 monReceived = uint256(int256(delta3.amount0()));

        // Verify profit & settle
        require(monReceived > monAmount, "Not profitable");
        uint256 profit = monReceived - monAmount;

        PM.take(MON, address(this), profit);

        (bool sent, ) = payable(owner).call{value: address(this).balance}("");
        require(sent, "ETH transfer failed");
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool sent, ) = payable(owner).call{value: ethBalance}("");
            require(sent, "ETH transfer failed");
        }

        IERC20 wbtc = IERC20(WBTC_ADDRESS);
        uint256 wbtcBalance = wbtc.balanceOf(address(this));
        if (wbtcBalance > 0) {
            wbtc.transfer(owner, wbtcBalance);
        }

        IERC20 ausd = IERC20(AUSD_ADDRESS);
        uint256 ausdBalance = ausd.balanceOf(address(this));
        if (ausdBalance > 0) {
            ausd.transfer(owner, ausdBalance);
        }
    }
}
