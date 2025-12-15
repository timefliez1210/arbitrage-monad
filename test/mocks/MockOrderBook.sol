// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockOrderBook {
    uint256 public bestBidPrice;
    uint256 public bestAskPrice;

    // Mock Data for L2 Book
    uint256 public bidSize;
    uint256 public askSize;

    function setBestBidAsk(uint256 _bid, uint256 _ask) external {
        bestBidPrice = _bid;
        bestAskPrice = _ask;
    }

    function setLiquidity(uint256 _bidSize, uint256 _askSize) external {
        bidSize = _bidSize;
        askSize = _askSize;
    }

    function bestBidAsk() external view returns (uint256, uint256) {
        return (bestBidPrice, bestAskPrice);
    }

    // Mock getL2Book to return encoded data matching the real contract's layout
    function getL2Book(uint32, uint32) external view returns (bytes memory) {
        // Layout: [Block] [BidPrice] [BidSize] [0] [AskPrice] [AskSize]
        // All 32 bytes (uint256)

        // Dynamic bytes array in memory:
        // [Length] [Data...]

        // We construct the data part.
        // 6 words = 192 bytes.

        bytes memory data = new bytes(192);

        uint256 _bidPrice = bestBidPrice; // Note: Real contract returns raw uint32 price?
        // Wait, Arbitrage.sol expects raw price in L2Book?
        // Arbitrage.sol actually IGNORES the price from L2Book and only reads size!
        // "bidSizeRaw := mload(add(dataPtr, 64))"
        // "askSizeRaw := mload(add(dataPtr, 160))"

        uint256 _bidSize = bidSize;
        uint256 _askSize = askSize;

        assembly {
            let start := add(data, 32)

            // 0: Block Number (Mock 1)
            mstore(start, 1)

            // 32: Bid Price
            mstore(add(start, 32), _bidPrice)

            // 64: Bid Size
            mstore(add(start, 64), _bidSize)

            // 96: Terminator (0)
            mstore(add(start, 96), 0)

            // 128: Ask Price
            mstore(add(start, 128), 0) // We don't use it, but let's put 0

            // 160: Ask Size
            mstore(add(start, 160), _askSize)
        }

        return data;
    }

    // Mock execution functions
    function placeAndExecuteMarketSell(
        uint96,
        uint256,
        bool,
        bool
    ) external payable returns (uint256) {
        return 0; // Return value not critical for profitability check unit test
    }

    function placeAndExecuteMarketBuy(
        uint96,
        uint256,
        bool,
        bool
    ) external payable returns (uint256) {
        return 0;
    }
}
