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
/// @dev Uses V4 flash accounting with EXACT INPUT swaps for correct decimal handling
///
/// Pool Configuration (all fee=500, tickSpacing=1):
/// - MON/WBTC: currency0=MON(18), currency1=WBTC(8)
/// - AUSD/WBTC: currency0=AUSD(6), currency1=WBTC(8)
/// - MON/AUSD: currency0=MON(18), currency1=AUSD(6)
///
/// Forward path: MON → WBTC → AUSD → MON (profitable when priceMonWbtc/priceAusdWbtc/priceMonAusd > 1)
/// Reverse path: MON → AUSD → WBTC → MON (profitable when priceMonAusd*priceAusdWbtc/priceMonWbtc > 1)
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
    /// @dev price = (sqrtPrice^2 * 10^(18 + decimals0 - decimals1)) / 2^192
    /// This gives: price of token1 in terms of token0 (how many token0 for 1 token1)
    function sqrtPriceToPrice(
        uint160 sqrtPriceX96,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 scaleFactor = 10 ** (18 + decimals0 - decimals1);
        return FullMath.mulDiv(sqrtPrice * sqrtPrice, scaleFactor, 1 << 192);
    }

    // ============ KEEPER PROFIT CHECK ============

    /// @notice Lightweight profit check for off-chain keeper
    /// @dev Only fetches prices, no liquidity queries for speed
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

        // Convert to prices (1e18 precision)
        // priceMonWbtc = WBTC per MON (token1/token0)
        // priceAusdWbtc = WBTC per AUSD
        // priceMonAusd = AUSD per MON
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

        // Total fees for 3 swaps: 3 * 0.05% = 0.15% = 15 bps
        uint256 totalFeeBps = 15;
        uint256 minOutput = (1e18 * (10000 + totalFeeBps)) / 10000;

        // Forward path: MON → WBTC → AUSD → MON
        // 1 MON → priceMonWbtc WBTC → (priceMonWbtc/priceAusdWbtc) AUSD → (priceMonWbtc/priceAusdWbtc/priceMonAusd) MON
        if (priceMonWbtc > 0 && priceAusdWbtc > 0 && priceMonAusd > 0) {
            uint256 forwardOutput = FullMath.mulDiv(
                FullMath.mulDiv(1e18, priceMonWbtc, priceAusdWbtc),
                1e18,
                priceMonAusd
            );

            if (forwardOutput > minOutput) {
                profitable = true;
                expectedProfit = forwardOutput - 1e18;
                return (profitable, expectedProfit);
            }
        }

        // Reverse path: MON → AUSD → WBTC → MON
        // 1 MON → priceMonAusd AUSD → (priceMonAusd*priceAusdWbtc) WBTC → (priceMonAusd*priceAusdWbtc/priceMonWbtc) MON
        if (priceAusdWbtc > 0 && priceMonAusd > 0 && priceMonWbtc > 0) {
            uint256 reverseOutput = FullMath.mulDiv(
                FullMath.mulDiv(1e18, priceMonAusd, 1e18),
                priceAusdWbtc,
                priceMonWbtc
            );

            if (reverseOutput > minOutput) {
                profitable = true;
                expectedProfit = reverseOutput - 1e18;
            }
        }
    }

    // ============ EXECUTE ============

    function execute() external returns (bool) {
        require(msg.sender == owner, "Not owner");

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

        uint256 totalFeeBps = 15;
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

        // Trade size: 10 MON
        uint256 tradeSize = 10 ether;

        bytes memory data = abi.encode(isForward, tradeSize);
        PM.unlock(data);

        return true;
    }

    // ============ UNLOCK CALLBACK ============

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(PM), "Only PM");

        (bool isForward, uint256 tradeSize) = abi.decode(data, (bool, uint256));

        if (isForward) {
            _executeForward(tradeSize);
        } else {
            _executeReverse(tradeSize);
        }

        return "";
    }

    /// @notice Forward path: MON → WBTC → AUSD → MON
    /// @dev Uses EXACT INPUT for each swap to handle different decimals correctly
    function _executeForward(uint256 monAmount) internal {
        // ============ SWAP 1: MON → WBTC (exact input MON) ============
        PoolKey memory keyMonWbtc = getPoolKeyMonWbtc();
        BalanceDelta delta1 = PM.swap(
            keyMonWbtc,
            IPoolManager.SwapParams({
                zeroForOne: true, // MON (token0) → WBTC (token1)
                amountSpecified: int256(monAmount), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // delta1.amount0() < 0 (spent MON), delta1.amount1() > 0 (received WBTC)
        require(delta1.amount1() > 0, "Swap1: no WBTC received");
        uint256 wbtcReceived = uint256(int256(delta1.amount1()));

        // ============ SWAP 2: WBTC → AUSD (exact input WBTC) ============
        PoolKey memory keyAusdWbtc = getPoolKeyAusdWbtc();
        BalanceDelta delta2 = PM.swap(
            keyAusdWbtc,
            IPoolManager.SwapParams({
                zeroForOne: false, // WBTC (token1) → AUSD (token0)
                amountSpecified: int256(wbtcReceived), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // delta2.amount0() > 0 (received AUSD), delta2.amount1() < 0 (spent WBTC)
        require(delta2.amount0() > 0, "Swap2: no AUSD received");
        uint256 ausdReceived = uint256(int256(delta2.amount0()));

        // ============ SWAP 3: AUSD → MON (exact input AUSD) ============
        PoolKey memory keyMonAusd = getPoolKeyMonAusd();
        BalanceDelta delta3 = PM.swap(
            keyMonAusd,
            IPoolManager.SwapParams({
                zeroForOne: false, // AUSD (token1) → MON (token0)
                amountSpecified: int256(ausdReceived), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // delta3.amount0() > 0 (received MON), delta3.amount1() < 0 (spent AUSD)
        require(delta3.amount0() > 0, "Swap3: no MON received");
        uint256 monReceived = uint256(int256(delta3.amount0()));

        // ============ VERIFY PROFIT & SETTLE ============
        require(monReceived > monAmount, "Not profitable");
        uint256 profit = monReceived - monAmount;

        // Take the net profit from PM
        PM.take(MON, address(this), profit);

        // Send profit to owner
        (bool sent, ) = payable(owner).call{value: address(this).balance}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Reverse path: MON → AUSD → WBTC → MON
    function _executeReverse(uint256 monAmount) internal {
        // ============ SWAP 1: MON → AUSD (exact input MON) ============
        PoolKey memory keyMonAusd = getPoolKeyMonAusd();
        BalanceDelta delta1 = PM.swap(
            keyMonAusd,
            IPoolManager.SwapParams({
                zeroForOne: true, // MON (token0) → AUSD (token1)
                amountSpecified: int256(monAmount), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        require(delta1.amount1() > 0, "Swap1: no AUSD received");
        uint256 ausdReceived = uint256(int256(delta1.amount1()));

        // ============ SWAP 2: AUSD → WBTC (exact input AUSD) ============
        PoolKey memory keyAusdWbtc = getPoolKeyAusdWbtc();
        BalanceDelta delta2 = PM.swap(
            keyAusdWbtc,
            IPoolManager.SwapParams({
                zeroForOne: true, // AUSD (token0) → WBTC (token1)
                amountSpecified: int256(ausdReceived), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        require(delta2.amount1() > 0, "Swap2: no WBTC received");
        uint256 wbtcReceived = uint256(int256(delta2.amount1()));

        // ============ SWAP 3: WBTC → MON (exact input WBTC) ============
        PoolKey memory keyMonWbtc = getPoolKeyMonWbtc();
        BalanceDelta delta3 = PM.swap(
            keyMonWbtc,
            IPoolManager.SwapParams({
                zeroForOne: false, // WBTC (token1) → MON (token0)
                amountSpecified: int256(wbtcReceived), // POSITIVE = exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        require(delta3.amount0() > 0, "Swap3: no MON received");
        uint256 monReceived = uint256(int256(delta3.amount0()));

        // ============ VERIFY PROFIT & SETTLE ============
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
