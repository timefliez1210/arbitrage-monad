// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./LocalIntegrationTest.t.sol";

contract ScenariosBenchmarkTest is LocalIntegrationTest {
    using StateLibrary for IPoolManager;

    // Use inherited `key` from Deployers

    function getKey() internal view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: 500,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            });
    }

    function test_Unprofitable_WithinSpread() public {
        vm.startPrank(address(this));
        // 1. Setup Kuru OrderBook
        marginAccount.deposit{value: 20000 ether}(
            address(this),
            address(0),
            20000 ether
        );
        ausd.mint(address(this), 20000 ether);
        ausd.approve(address(marginAccount), type(uint256).max);
        marginAccount.deposit(address(this), address(ausd), 20000 ether);

        // Buy @ 0.8. Sell @ 1.2.
        // Uni @ 1.0 (or 0.9 if it persists).
        // If Uni=1.0. Bid=0.8. 0.8 < 1.0. No Arb (Forward).
        // Ask=1.2. 1.0 < 1.2. No Arb (Reverse).

        orderBook.addBuyOrder(8000000, 5e13, false); // 0.8
        orderBook.addSellOrder(12000000, 5e13, false); // 1.2

        // Uni @ 1.0.
        // Correct SqrtPrice for 1.0 (AUSD/MON 1:1) -> Raw 1e-12 -> Sqrt 1e-6 -> 2^96 * 1e-6
        uint160 initSqrtPrice = 79228162514264337593543;
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            bytes("")
        );

        // 3. Check Profitability
        (
            bool profitable,
            ,
            ,
            uint256 price1e18,
            uint256 bestBidOut,
            uint256 bestAskOut,

        ) = arbAUSD.calculateProfit();
        console.log("Profit (WithinSpread):", profitable);
        console.log("Uni Price:", price1e18);
        console.log("Best Bid:", bestBidOut);
        console.log("Best Ask:", bestAskOut);

        assertFalse(profitable, "Should not be profitable within spread");
    }

    function test_Unprofitable_LowLiquidity_Forward() public {
        vm.startPrank(address(this));
        marginAccount.deposit{value: 20000 ether}(
            address(this),
            address(0),
            20000 ether
        );

        // Buy @ 1.0. Size 250 MON.
        orderBook.addBuyOrder(10000000, 25000000000000, false);

        // Uni Price ~0.9999.
        uint160 initSqrtPrice = 79224162514264337593543;
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -280000,
                tickUpper: -270000,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            bytes("")
        );

        // 3. Execution (Forward Low Liq)
        // Ensure Uni Price ~1.0. Bid 1.0.
        // If Uni < Bid, Forward Arb triggers.
        // Uni 0.99 (7.92e22). Bid 1.0. Profitable spread.
        // But Low Liquidity -> Should fail.

        (bool profitable, , , , , , ) = arbAUSD.calculateProfit();
        assertFalse(profitable, "Micro spread should fail threshold");
    }

    function test_Unprofitable_LowLiquidity_Reverse() public {
        vm.startPrank(address(this));
        ausd.mint(address(this), 20000 ether);
        ausd.approve(address(marginAccount), type(uint256).max);
        marginAccount.deposit(address(this), address(ausd), 20000 ether);

        // Sell @ 1.0. Size 250 MON.
        orderBook.addSellOrder(10000000, 25000000000000, false);

        // Uni Price ~1.0001.
        uint160 initSqrtPrice = 79232162514264337593543;
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            bytes("")
        );

        // 3. Execution
        (bool profitable, , , , , , ) = arbAUSD.calculateProfit();
        assertFalse(profitable, "Micro spread should fail threshold");
    }

    function test_Benchmark_HighLoad() public {
        vm.startPrank(address(this));
        // 1. Setup MANY Orders to stress gas
        ausd.mint(address(this), 20000000 ether);
        // Create 40 orders in Kuru Orderbook
        // Populate Sells (Asks). Reverse Arb logic scans Asks.
        // Needs MON deposit for Sells (NATIVE_IN_BASE -> Base is MON).

        // FIX: Ensure sufficient ETH balance
        vm.deal(address(this), 1e30);

        marginAccount.deposit{value: 20000 ether}(
            address(this),
            address(0),
            20000 ether
        );

        uint256 basePrice = 9000000; // 0.9

        // Setup sells
        for (uint256 i = 0; i < 40; i++) {
            // Size: 250 MON Each. Raw 2.5e13.
            orderBook.addSellOrder(
                uint32(basePrice + (i * 10000)),
                25000000000000,
                false
            );
        }

        // Setup Uni at 1.5 (High) -> Should trigger Reverse Arb
        // 1.5 Ratio 1.5e-12. Sqrt ~1.22e-6.
        // 1.22e-6 * 2^96 ~= 9.7e22.
        uint160 initSqrtPrice = 97000000000000000000000;
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            bytes("")
        );

        uint256 startGas = gasleft();
        (bool profitable, , , , , , ) = arbAUSD.calculateProfit();
        uint256 usedGas = startGas - gasleft();

        console.log("Benchmark Gas Used (CalculateProfit):", usedGas);
        assertTrue(profitable, "Should be profitable");
    }

    function test_NativeExecution_Forward() public {
        vm.startPrank(address(this));

        ausd.mint(address(this), 200 ether);
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(marginAccount), type(uint256).max);
        marginAccount.deposit(address(this), address(ausd), 200 ether);

        // Setup Forward Arb: Buy Uni (Low), Sell Kuru (High)
        // Kuru: Sell Price (Bid) = 1.1
        // Uni: Price = 0.9

        uint256 basePrice = 11000000; // 1.1
        orderBook.addBuyOrder(uint32(basePrice), 5e13, false); // 500 MON

        // Uni @ 0.9.
        uint160 initSqrtPrice = 75000000000000000000000; // Approx 0.9
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            bytes("")
        );

        uint256 startBalance = ausd.balanceOf(arbAUSD.owner());

        uint256 startGas = gasleft();
        bool success = arbAUSD.execute();
        uint256 usedGas = startGas - gasleft();

        assertTrue(success, "Execution failed");
        uint256 endBalance = ausd.balanceOf(arbAUSD.owner());
        console.log("Native Forward Gas:", usedGas);
        console.log("Profit:", endBalance - startBalance);
        assertTrue(endBalance > startBalance, "No profit made");
    }

    function test_NativeExecution_Reverse() public {
        vm.startPrank(address(this));
        // Setup Reverse Arb: Sell Uni (High), Buy Kuru (Low)
        // Kuru: Buy Price (Ask) = 0.9
        // Uni: Price = 1.1

        // Funding
        vm.deal(address(this), 1e30);
        marginAccount.deposit{value: 20000 ether}(
            address(this),
            address(0),
            20000 ether
        );
        ausd.mint(address(this), 2000 ether);
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(marginAccount), type(uint256).max);

        uint256 basePrice = 9000000; // 0.9
        // Sell Order (Ask) on Kuru
        orderBook.addSellOrder(uint32(basePrice), 5e13, false);

        // Uni @ 1.1 (~8.3e22)
        uint160 initSqrtPrice = 83000000000000000000000;
        key = getKey();
        manager.initialize(key, initSqrtPrice);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            bytes("")
        );

        PoolId pid = key.toId();
        uint128 setupLiq = manager.getLiquidity(pid);
        console.log("Setup Liquidity:", setupLiq);
        require(setupLiq > 0, "Setup failed to add liquidity");

        uint256 startMonBalance = arbAUSD.owner().balance;
        uint256 startBalance = ausd.balanceOf(arbAUSD.owner());

        uint256 startGas = gasleft();
        bool success = arbAUSD.execute();
        uint256 usedGas = startGas - gasleft();

        assertTrue(success, "Execution failed");

        // Check Profit in ARB CONTRACT
        uint256 endBalance = arbAUSD.owner().balance;

        uint256 ausdEnd = ausd.balanceOf(address(this));

        console.log("Native Reverse Gas:", usedGas);
        console.log("Profit (MON):", endBalance - startMonBalance); // Assuming startMonBalance tracked

        // In Reverse arb with Native logic, we keep profit in MON (excess base).
        assertTrue(endBalance > startMonBalance, "No profit made (MON)");
    }
}
