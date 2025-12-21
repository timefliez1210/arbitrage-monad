// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";
import {
    FixedPointMathLib
} from "@kuru/contracts/libraries/FixedPointMathLib.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {
    IPancakeV3Pool,
    IPancakeV3SwapCallback
} from "./interfaces/IPancakeV3Pool.sol";
import {IWMON} from "./interfaces/IWMON.sol";

/// @title ArbitragePancakeUSDC
/// @notice Arbitrage between PancakeV3 WMON/USDC pool and Kuru MON/USDC orderbook
/// @dev PCS Pool: WMON = token0, USDC = token1
///      Uses PCS swap callback as flash loan
contract ArbitragePancakeUSDC is IPancakeV3SwapCallback {
    // ============ ERRORS ============
    error Unauthorized();
    error InsufficientOutput();

    // ============ IMMUTABLES ============
    IPancakeV3Pool public immutable PCS_POOL;
    IOrderBook public immutable OB;
    IWMON public immutable WMON;
    IERC20 public immutable USDC;
    address public immutable owner;

    // Kuru precision params
    uint256 public immutable PRICE_PRECISION;
    uint256 public immutable SIZE_PRECISION;
    uint256 constant QUOTE_MULTIPLIER = 1e6;
    uint256 constant BASE_MULTIPLIER = 1e18;
    uint256 constant PRICE_SCALE_FACTOR = 1e30; // 18 + 18 - 6

    // ============ CONSTRUCTOR ============
    constructor(
        address _pcsPool,
        address _kuruOrderBook,
        address _wmon,
        address _usdc,
        address _owner
    ) {
        PCS_POOL = IPancakeV3Pool(_pcsPool);
        OB = IOrderBook(_kuruOrderBook);
        WMON = IWMON(_wmon);
        USDC = IERC20(_usdc);
        owner = _owner;

        // Fetch Kuru params
        (uint32 pp, uint96 sp, , , , , , , , , ) = OB.getMarketParams();
        PRICE_PRECISION = uint256(pp);
        SIZE_PRECISION = uint256(sp);
    }

    receive() external payable {}

    // ============ PRICE QUERIES ============

    /// @notice Get PCS price (USDC per MON in 1e18)
    /// @dev Pool is WMON/USDC: token0=WMON, token1=USDC
    ///      sqrtPriceX96 gives sqrt(token1/token0) = sqrt(USDC/WMON)
    function getPancakePrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = PCS_POOL.slot0();

        // price = sqrtPriceX96^2 * SCALE / 2^192 = USDC/WMON
        uint256 price = FullMath.mulDiv(
            uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
            PRICE_SCALE_FACTOR,
            1 << 192
        );
        return price;
    }

    // ============ KEEPER PROFIT ============

    function keeperProfit()
        external
        view
        returns (bool profitable, uint256 expectedProfit)
    {
        uint256 pcsPrice = getPancakePrice();
        (uint256 kuruBid, uint256 kuruAsk) = OB.bestBidAsk();
        uint256 fee = (pcsPrice * 7) / 10000;

        // Forward: PCS cheap, Kuru dear
        if (pcsPrice < kuruBid && kuruBid > pcsPrice + fee) {
            uint256 kuruSize = getAggregatedBidSize(20, pcsPrice + fee);
            if (kuruSize > 0) {
                uint256 spread = ((kuruBid - pcsPrice) * 94) / 100;
                uint256 margin = (kuruBid * 45) / 10000;
                if (spread > fee + margin) {
                    expectedProfit =
                        ((spread - fee - margin) * kuruSize) /
                        1e18;
                    if (expectedProfit > 15e15) profitable = true;
                }
            }
        }
        // Reverse: Kuru cheap, PCS dear
        else if (
            pcsPrice > kuruAsk && kuruAsk > 0 && kuruAsk < pcsPrice - fee
        ) {
            (uint256 kuruSize, ) = getAggregatedAskSize(20, pcsPrice - fee);
            if (kuruSize > 0) {
                uint256 spread = ((pcsPrice - kuruAsk) * 94) / 100;
                uint256 margin = (kuruAsk * 27) / 10000;
                if (spread > fee + margin) {
                    expectedProfit =
                        ((spread - fee - margin) * kuruSize) /
                        pcsPrice;
                    if (expectedProfit > 0.75 ether) profitable = true;
                }
            }
        }
    }

    // ============ EXECUTE ============

    function execute() public returns (bool) {
        uint256 pcsPrice = getPancakePrice();
        (uint256 kuruBid, uint256 kuruAsk) = OB.bestBidAsk();
        uint256 fee = (pcsPrice * 7) / 10000;

        if (pcsPrice + fee < kuruBid) {
            // Forward: Buy WMON on PCS, sell MON on Kuru
            uint256 kuruVolWei = getAggregatedBidSize(50, pcsPrice + fee);
            if (kuruVolWei == 0) return false;

            uint256 wmonToBuy = (kuruVolWei * 9975) / 10000;

            // zeroForOne = false → USDC (token1) -> WMON (token0)
            // amountSpecified = negative → exactOutput (we want WMON)
            PCS_POOL.swap(
                address(this),
                false, // USDC -> WMON
                -int256(wmonToBuy),
                1461446703485210103287273052203988822378723970341, // max sqrtPrice
                abi.encode(true, kuruVolWei)
            );
            return true;
        } else if (pcsPrice > kuruAsk + fee && kuruAsk > 0) {
            // Reverse: Buy MON on Kuru, sell WMON on PCS
            (uint256 kuruVolWei, uint256 maxQuoteSpend) = getAggregatedAskSize(
                50,
                pcsPrice - fee
            );
            if (kuruVolWei == 0) return false;

            // zeroForOne = true → WMON (token0) -> USDC (token1)
            // We want USDC first to buy on Kuru
            PCS_POOL.swap(
                address(this),
                true, // WMON -> USDC
                -int256(maxQuoteSpend),
                4295128740, // min sqrtPrice
                abi.encode(false, kuruVolWei, maxQuoteSpend)
            );
            return true;
        }

        return false;
    }

    // ============ PCS CALLBACK ============

    function pancakeV3SwapCallback(
        int256 amount0Delta, // WMON delta
        int256 amount1Delta, // USDC delta
        bytes calldata data
    ) external {
        if (msg.sender != address(PCS_POOL)) revert Unauthorized();

        bool isForward = abi.decode(data, (bool));

        if (isForward) {
            // Forward: We got WMON (amount0Delta < 0), owe USDC (amount1Delta > 0)
            uint256 wmonReceived = uint256(-amount0Delta);
            uint256 usdcOwed = uint256(amount1Delta);

            // Unwrap WMON -> MON
            WMON.withdraw(wmonReceived);

            // Sell MON on Kuru for USDC
            uint96 monToSell = uint96(
                (wmonReceived * SIZE_PRECISION) / BASE_MULTIPLIER
            );
            OB.placeAndExecuteMarketSell{value: wmonReceived}(
                monToSell,
                0,
                false,
                false
            );

            // Pay USDC to PCS
            uint256 usdcBal = USDC.balanceOf(address(this));
            if (usdcBal < usdcOwed) revert InsufficientOutput();
            USDC.transfer(msg.sender, usdcOwed);

            // Send profit to owner
            uint256 profit = USDC.balanceOf(address(this));
            if (profit > 0) USDC.transfer(owner, profit);
        } else {
            // Reverse: We got USDC (amount1Delta < 0), owe WMON (amount0Delta > 0)
            (, uint256 kuruVolWei, ) = abi.decode(
                data,
                (bool, uint256, uint256)
            );

            uint256 usdcReceived = uint256(-amount1Delta);
            uint256 wmonOwed = uint256(amount0Delta);

            // Buy MON on Kuru with USDC
            uint96 quoteInput = uint96(
                (usdcReceived * PRICE_PRECISION) / QUOTE_MULTIPLIER
            );
            USDC.approve(address(OB), usdcReceived);
            OB.placeAndExecuteMarketBuy(quoteInput, 0, false, false);

            // Wrap MON -> WMON (cap to kuruVolWei)
            uint256 monBal = address(this).balance;
            uint256 monToWrap = monBal > kuruVolWei ? kuruVolWei : monBal;
            WMON.deposit{value: monToWrap}();

            // Pay WMON to PCS
            uint256 wmonBal = WMON.balanceOf(address(this));
            if (wmonBal < wmonOwed) revert InsufficientOutput();
            WMON.transfer(msg.sender, wmonOwed);

            // Unwrap any remaining WMON to MON
            uint256 wmonRemaining = WMON.balanceOf(address(this));
            if (wmonRemaining > 0) {
                WMON.withdraw(wmonRemaining);
            }

            // Send all remaining MON profit to owner
            if (address(this).balance > 0) {
                payable(owner).call{value: address(this).balance}("");
            }
        }
    }

    // ============ ADMIN ============

    function emergencyWithdraw() external {
        require(msg.sender == owner, "Not owner");

        // Withdraw native MON
        if (address(this).balance > 0) {
            payable(owner).call{value: address(this).balance}("");
        }

        // Withdraw WMON (unwrap first)
        uint256 wmonBal = WMON.balanceOf(address(this));
        if (wmonBal > 0) {
            WMON.withdraw(wmonBal);
            payable(owner).call{value: address(this).balance}("");
        }

        // Withdraw USDC
        uint256 usdcBal = USDC.balanceOf(address(this));
        if (usdcBal > 0) {
            USDC.transfer(owner, usdcBal);
        }
    }

    // ============ KURU QUERIES ============

    function getAggregatedBidSize(
        uint32 ticksBid,
        uint256 minPrice
    ) public view returns (uint256 totalSizeWei) {
        uint256 totalSizeRaw;
        uint256 minPriceRaw = minPrice / (BASE_MULTIPLIER / PRICE_PRECISION);
        bytes memory data = OB.getL2Book(ticksBid, 0);

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
        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / SIZE_PRECISION;
    }

    function getAggregatedAskSize(
        uint32 ticksAsk,
        uint256 maxPrice
    ) public view returns (uint256 totalSizeWei, uint256 totalCostUSDC) {
        uint256 pricePrecision = PRICE_PRECISION;
        uint256 sizePrecision = SIZE_PRECISION;
        uint256 totalSizeRaw;
        uint256 maxPriceRaw = maxPrice / (BASE_MULTIPLIER / PRICE_PRECISION);
        bytes memory data = OB.getL2Book(0, ticksAsk);

        assembly {
            let ptr := add(data, 96)
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
                let costRaw := mul(size, price)
                let cost := div(
                    mul(costRaw, 1000000),
                    mul(sizePrecision, pricePrecision)
                )
                totalCostUSDC := add(totalCostUSDC, cost)
                ptr := add(ptr, 64)
            }
        }
        totalSizeWei = (totalSizeRaw * BASE_MULTIPLIER) / SIZE_PRECISION;
    }
}
