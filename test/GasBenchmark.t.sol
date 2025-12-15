// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ArbitrageAUSD} from "../src/ArbitrageAUSD.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract GasBenchmark is Test {
    ArbitrageAUSD public arbitrage;
    address constant AUSD_ADDRESS = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant KURU_OB = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;
    address constant PM_ADDRESS = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;

    function setUp() public {
        string memory RPC = vm.envString("ALCHEMY_HTTPS_API");
        vm.createSelectFork(RPC);

        arbitrage = new ArbitrageAUSD(
            PM_ADDRESS,
            KURU_OB,
            AUSD_ADDRESS,
            address(this)
        );

        // Fund contract
        deal(address(arbitrage), 10000 ether);

        // Fund AUSD via Whale
        address whale = 0x465A0B350bb6a7eFF750729f1D866d67F0b53980;
        vm.prank(whale);
        IERC20(AUSD_ADDRESS).transfer(address(arbitrage), 10000 * 1e6);

        // Approve
        vm.startPrank(address(arbitrage));
        IERC20(AUSD_ADDRESS).approve(PM_ADDRESS, type(uint256).max);
        IERC20(AUSD_ADDRESS).approve(KURU_OB, type(uint256).max);
        vm.stopPrank();
    }

    function test_BenchmarkGas_Forward() public {
        // Forward: Buy Uniswap (Low), Sell Kuru (High)
        // We simulate Kuru Bid Price being VERY HIGH to force a large search range on Uniswap

        // Mock Kuru bestBidAsk
        // Bid = 1.0 (1e18), Ask = 1.1 (1.1e18)
        // Current Uniswap Price is likely low (~0.0002 or 0.02)
        uint256 highBid = 1 ether;
        uint256 highAsk = 1.1 ether;
        vm.mockCall(
            KURU_OB,
            abi.encodeWithSignature("bestBidAsk()"),
            abi.encode(highBid, highAsk)
        );

        // Mock getL2Book for Bid side (Forward)
        // Return 1000 MON size at highBid price
        // Logic: price (32) + size (32). Left aligned size for mainnet?
        // Let's rely on standard right aligned for mock or check code.
        // Code checks: if (size > 1e30) shr.
        // We'll provide a normal size: 1000 ether.

        // Encoding manual byte array for L2Book
        // Price: 1e7 precision. 1 ether (1e18) -> 1e7. 1e7.
        uint256 priceRaw = 10000000;
        uint256 sizeRaw = 1000 * 1e11; // 1000 MON * 1e11? No.
        // BASE(18) / SIZE(11) = 7.
        // Wei = Raw * 1e7. So SizeRaw = Wei / 1e7.
        // Size = 1000e18 / 1e7 = 1000e11.

        bytes memory bookData = abi.encodePacked(
            uint256(1234), // block
            uint256(1234), // block
            uint256(priceRaw),
            uint256(sizeRaw)
            // End with 0 price to signal stop
        );
        // Actually getL2Book returns `bytes`.
        // The parser skips 64 bytes.
        bytes memory payload = abi.encodePacked(
            bytes32(0),
            bytes32(0), // Skip 64
            uint256(priceRaw),
            uint256(sizeRaw),
            uint256(0) // terminator
        );

        vm.mockCall(
            KURU_OB,
            abi.encodeWithSignature("getL2Book(uint32,uint32)", 50, 0),
            payload
        );

        // Also mock placeAndExecuteMarketSell to avoid Kuru logic and reverts
        vm.mockCall(
            KURU_OB,
            abi.encodeWithSignature(
                "placeAndExecuteMarketSell(uint96,uint96,bool,bool)"
            ),
            abi.encode(0) // returns nothing? or OrderId?
        );

        // Measure Gas
        uint256 gasStart = gasleft();
        bool success = arbitrage.execute();
        uint256 gasEnd = gasleft();

        console.log("Execution Success:", success);
        console.log("Gas Used:", gasStart - gasEnd);
    }
}
