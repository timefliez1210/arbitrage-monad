// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract MockKuru {
    uint256 public bidPrice;
    uint256 public askPrice;
    uint256 public sellReturn;
    uint256 public buyReturn;

    address public usdc;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setBestBidAsk(uint256 _bid, uint256 _ask) external {
        bidPrice = _bid;
        askPrice = _ask;
    }

    function setSellReturn(uint256 _amount) external {
        sellReturn = _amount;
    }

    function setBuyReturn(uint256 _amount) external {
        buyReturn = _amount;
    }

    function bestBidAsk() external view returns (uint256, uint256) {
        return (bidPrice, askPrice);
    }

    function placeAndExecuteMarketSell(
        uint96 size,
        uint256,
        bool,
        bool
    ) external payable returns (uint256) {
        // Size is in Lots.
        // We need to convert to Wei to calculate value?
        // Or just assume Size * BidPrice?
        // BidPrice is e18 (USDC per MON).
        // Size is Lots (MON / 1e7).
        // AmountMON = Size * 1e7.
        // Value = AmountMON * BidPrice / 1e30 (if BidPrice is e18 and we want USDC e6).

        // Let's assume BidPrice is correctly scaled to produce USDC output.
        // If BidPrice = 0.05 USDC (5e16).
        // AmountMON = 100e18.
        // Value = 5e6.
        // 100e18 * 5e16 = 500e34.
        // We need 5e6. Divisor = 1e28.

        uint256 amountMON = uint256(size) * 1e7;
        // Value = amountMON * bidPrice / 1e30?
        // If bidPrice is 5e16 (0.05).
        // 1e18 * 5e16 = 5e34.
        // We want 0.05 USDC (5e4).
        // 5e34 / 1e30 = 5e4.

        uint256 returnAmount = (amountMON * bidPrice) / 1e30;

        if (returnAmount > 0) {
            IERC20(usdc).transfer(msg.sender, returnAmount);
        }
        return returnAmount;
    }

    function placeAndExecuteMarketBuy(
        uint96 quoteAmount,
        uint256,
        bool,
        bool
    ) external payable returns (uint256) {
        // QuoteAmount is USDC (e6).
        // We want MON (e18).
        // Price is AskPrice (USDC per MON).
        // AmountMON = QuoteAmount / AskPrice?
        // QuoteAmount = 1 USDC (1e6).
        // AskPrice = 0.01 USDC (1e16).
        // Result = 100 MON (100e18).
        // 1e6 * ? / 1e16 = 100e18.
        // 1e6 * 1e30 / 1e16 = 1e36 / 1e16 = 1e20 = 100e18.

        uint256 returnAmount = (uint256(quoteAmount) * 1e30) / askPrice;

        if (returnAmount > 0) {
            (bool success, ) = msg.sender.call{value: returnAmount}("");
            require(success, "ETH transfer failed");
        }
        return returnAmount;
    }

    receive() external payable {}
}
