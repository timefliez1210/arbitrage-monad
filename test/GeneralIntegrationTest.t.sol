// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {OrderBook} from "@kuru/contracts/OrderBook.sol";
import {OrderBook as OrderBookImpl} from "@kuru/contracts/OrderBook.sol";
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";
import {Router} from "@kuru/contracts/Router.sol";
import {MarginAccount} from "@kuru/contracts/MarginAccount.sol";
import {KuruForwarder} from "@kuru/contracts/KuruForwarder.sol";
import {KuruAMMVault} from "@kuru/contracts/KuruAMMVault.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArbitrageKuruUniswap} from "../src/ArbitrageKuruUniswap.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract GeneralIntegrationTest is Deployers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MockERC20 ausd;
    MockERC20 usdc;

    // Kuru Ecosystem
    Router kuruRouter;
    MarginAccount marginAccount;
    OrderBookImpl orderBookImpl;
    KuruAMMVault kuruAmmVaultImpl;
    KuruForwarder kuruForwarder;
    OrderBook orderBook;
    KuruAMMVault vault;

    // Arbitrage Contract
    ArbitrageKuruUniswap arbBot;

    function setUp() public virtual {
        // 1. Deploy Uniswap V4 Environment
        deployFreshManagerAndRouters();

        // 2. Deploy Tokens
        // AUSD: 6 decimals (Simulating reality for testing specific scenario if needed, currently 6)
        // Note: ArbitrageAUSD.sol assumed 6 decimals for AUSD.
        // We will stick to that to match previous tests.
        ausd = new MockERC20("AUSD", "AUSD", 6);
        usdc = new MockERC20("USDC", "USDC", 6);

        // 3. Deploy Kuru Ecosystem
        KuruForwarder implementation = new KuruForwarder();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        kuruForwarder = KuruForwarder(address(proxy));
        bytes4[] memory allowedInterfaces = new bytes4[](6);
        allowedInterfaces[0] = OrderBook.addBuyOrder.selector;
        allowedInterfaces[1] = OrderBook.addSellOrder.selector;
        allowedInterfaces[2] = OrderBook.placeAndExecuteMarketBuy.selector;
        allowedInterfaces[3] = OrderBook.placeAndExecuteMarketSell.selector;
        allowedInterfaces[4] = MarginAccount.deposit.selector;
        allowedInterfaces[5] = MarginAccount.withdraw.selector;
        kuruForwarder.initialize(address(this), allowedInterfaces);

        Router routerImpl = new Router();
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), "");
        kuruRouter = Router(payable(address(routerProxy)));

        MarginAccount marginAccountImpl = new MarginAccount();
        ERC1967Proxy marginProxy = new ERC1967Proxy(
            address(marginAccountImpl),
            ""
        );
        marginAccount = MarginAccount(payable(address(marginProxy)));
        marginAccount.initialize(
            address(this),
            address(kuruRouter),
            address(kuruRouter),
            address(kuruForwarder)
        );

        orderBookImpl = new OrderBookImpl();
        kuruAmmVaultImpl = new KuruAMMVault();

        kuruRouter.initialize(
            address(this),
            address(marginAccount),
            address(orderBookImpl),
            address(kuruAmmVaultImpl),
            address(kuruForwarder)
        );

        // Create Market via Router (MON/AUSD)
        // Base: MON (address(0)), Quote: AUSD
        address marketProxy = kuruRouter.deployProxy(
            IOrderBook.OrderBookType.NATIVE_IN_BASE,
            address(0),
            address(ausd),
            1e11,
            1e7,
            1,
            2e13,
            2e17,
            20,
            0,
            100
        );
        orderBook = OrderBook(payable(marketProxy));

        address vaultAddr = kuruRouter.computeVaultAddress(
            marketProxy,
            address(kuruAmmVaultImpl),
            false
        );
        vault = KuruAMMVault(payable(vaultAddr));

        // Fund Vault
        vm.deal(address(this), 1000 * 1e18);
        ausd.mint(address(this), 1000 * 1e6);
        ausd.approve(address(vault), type(uint256).max);
        vault.deposit{value: 1e18}(1e18, 1e6, address(this));

        // Register market

        currency0 = Currency.wrap(address(0)); // MON
        currency1 = Currency.wrap(address(ausd)); // AUSD

        // 5. Deploy Generic Arbitrage Contract
        vm.startPrank(address(this));
        arbBot = new ArbitrageKuruUniswap(
            address(manager),
            address(orderBook),
            address(0), // Base: MON (18 dec)
            address(ausd), // Quote: AUSD (6 dec)
            address(this)
        );

        // Fund Accounts
        vm.deal(address(this), 100000 ether);
        ausd.mint(address(this), 100000 ether);
        ausd.mint(address(arbBot), 10000 * 1e6); // Capital

        ausd.approve(address(marginAccount), type(uint256).max);
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(swapRouter), type(uint256).max);

        marginAccount.deposit(address(this), address(ausd), 500 * 1e6);
        marginAccount.deposit{value: 500 * 1e18}(
            address(this),
            address(0),
            500 * 1e18
        );
        vm.stopPrank();
    }

    function test_ForwardArbitrage_MON_AUSD() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));

        // 1. Setup Kuru (High Price). Bid 1.0.
        // Size: 500 MON.
        orderBook.addBuyOrder(10000000, 5e13, false);

        // 2. Setup Uni (Low Price). 0.9.
        // SqrtPrice Calculation (MON/AUSD specific):
        // 1 AUSD = 0.9 USDC? No. Quote/Base.
        // Price = Quote/Base.
        // AUSD (Quote, 6dec) / MON (Base, 18dec).
        // 1 MON = X AUSD.
        // OrderBook Price 1.0 means 1 MON = 1 AUSD.
        // We want Uni Price = 0.9 AUSD per MON.
        // Ratio = 0.9 * 1e6 / 1e18 = 0.9 * 1e-12.
        // Sqrt(0.9 * 1e-12) * 2^96 = 7.51e22.
        uint160 sqrtPrice09 = 75100000000000000000000;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, sqrtPrice09);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: 0
            }),
            ZERO_BYTES
        );

        // 3. Check Profitability
        (
            bool profitable,
            ,
            ,
            uint256 price1e18,
            ,
            ,
            uint256 expectedProfit,

        ) = arbBot.calculateProfit();

        console.log("Profitable:", profitable);
        console.log("Expected Profit:", expectedProfit);
        console.log("Uni Price:", price1e18);

        assertTrue(profitable, "Should be profitable");

        // 4. Execute
        uint256 balanceBefore = ausd.balanceOf(address(this));
        bool executed = arbBot.execute();
        assertTrue(executed, "Execution failed");
        uint256 balanceAfter = ausd.balanceOf(address(this));

        console.log("Profit Earned:", balanceAfter - balanceBefore);
        assertTrue(balanceAfter > balanceBefore, "No profit made");
    }

    function test_ReverseArbitrage_MON_AUSD() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));

        // 1. Setup Kuru (Low Price). Ask 1.0.
        orderBook.addSellOrder(10000000, 5e13, false);

        // 2. Setup Uni (High Price). 1.1.
        // SqrtPrice: 8.3e22.
        uint160 sqrtPrice11 = 83000000000000000000000;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, sqrtPrice11);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: 0
            }),
            ZERO_BYTES
        );

        // 3. Check Profitability
        (bool profitable, , , , , , , ) = arbBot.calculateProfit();
        assertTrue(profitable, "Should be profitable");

        // 4. Execute
        uint256 balanceBefore = address(this).balance;

        bool executed = arbBot.execute();
        assertTrue(executed, "Execution failed");

        uint256 balanceAfter = address(this).balance;
        console.log("Profit Earned:", balanceAfter - balanceBefore);
        assertTrue(balanceAfter > balanceBefore, "No profit made");
    }

    function test_ForwardArbitrage_USDC_AUSD() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));

        // 1. Deploy USDC/AUSD Market
        // Base: USDC (6), Quote: AUSD (6)
        // Note: Generic deployment test
        address marketProxy = kuruRouter.deployProxy(
            IOrderBook.OrderBookType.NO_NATIVE,
            address(usdc),
            address(ausd),
            1e6, // Size Prec (1 USDC = 1 e6)
            1e7, // Price Prec
            1,
            1e6, // Min Size 1 USDC
            2e17, // Max
            20,
            0,
            100
        );
        OrderBook obUSDC = OrderBook(payable(marketProxy));
        address vaultAddr = kuruRouter.computeVaultAddress(
            marketProxy,
            address(kuruAmmVaultImpl),
            false
        );
        KuruAMMVault vaultUSDC = KuruAMMVault(payable(vaultAddr));

        // Fund Vault
        usdc.mint(address(this), 1e30);
        ausd.mint(address(this), 1e30);
        usdc.approve(address(vaultUSDC), type(uint256).max);
        ausd.approve(address(vaultUSDC), type(uint256).max);
        vaultUSDC.deposit(1e6, 1e6, address(this));

        // 2. Deploy Arb Bot
        ArbitrageKuruUniswap arbBotUSDC = new ArbitrageKuruUniswap(
            address(manager),
            address(obUSDC),
            address(usdc),
            address(ausd),
            address(this)
        );

        // Fund Bot
        ausd.mint(address(arbBotUSDC), 10000 * 1e6); // Capital

        // 3. Setup Trade
        // Kuru Buy Order (Bid) at 1.0 (1e7). Size 500 USDC.
        obUSDC.addBuyOrder(10000000, 500 * 1e6, false);

        // Uni Price 0.9.
        uint160 sqrtPrice09 = 75100000000000000000000;

        Currency c0 = address(usdc) < address(ausd)
            ? Currency.wrap(address(usdc))
            : Currency.wrap(address(ausd));
        Currency c1 = address(usdc) < address(ausd)
            ? Currency.wrap(address(ausd))
            : Currency.wrap(address(usdc));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        // Dynamic Start Price:
        // Forward Arb needs Base Cheap on Uni. (Base/Quote Low).
        // If Base=0 (P=Q/B). 0.9 (Low).
        // If Base=1 (P=B/Q). 1.11 (High). (Inverse is Low).

        uint160 initialSqrtPrice;
        if (address(usdc) < address(ausd)) {
            // USDC < AUSD. T0=USDC. T1=AUSD.
            // Price = T1/T0 = AUSD/USDC.
            // Uni Price (Start) = 0.9. (Cheap Base?? No Base=USDC).
            // Forward Arb: Buy Base on Uni. Sell Base on Kuru.
            // Uni Price < Kuru Bid.
            // Kuru Bid = 1.0. Uni Price = 0.9.
            // So we want Price = 0.9.
            // Sqrt(0.9)*2^96 = 7.51e28.
            initialSqrtPrice = 75100000000000000000000000000; // 0.9
        } else {
            // USDC > AUSD. T0=AUSD. T1=USDC.
            // Price = T1/T0 = USDC/AUSD.
            // Wait. Base=USDC. Quote=AUSD.
            // Price is Quote/Base?? No. Uniswap is T1/T0.
            // Price = USDC/AUSD. This is Base/Quote (1/Display).
            // We want Display Price = 0.9.
            // So Base/Quote (Inverse) = 1/0.9 = 1.11.
            // Sqrt(1.11)*2^96 = 8.34e28.
            initialSqrtPrice = 83400000000000000000000000000; // 1.11
        }

        manager.initialize(key, initialSqrtPrice);

        // Approve Routers for USDC/AUSD
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(swapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: 0
            }),
            ZERO_BYTES
        );

        // 4. Exec
        (bool profitable, , , , , , , ) = arbBotUSDC.calculateProfit();
        assertTrue(profitable, "Should be profitable");

        bool executed = arbBotUSDC.execute();
        assertTrue(executed, "Execution failed");
    }

    function test_ReverseArbitrage_USDC_AUSD() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));

        // 1. Deploy & Setup Market (Same as Forward)
        address marketProxy = kuruRouter.deployProxy(
            IOrderBook.OrderBookType.NO_NATIVE,
            address(usdc),
            address(ausd),
            1e6, // Size Prec
            1e7, // Price Prec
            1,
            1e6, // Min
            2e17, // Max
            20,
            0,
            100
        );
        OrderBook obUSDC = OrderBook(payable(marketProxy));
        address vaultAddr = kuruRouter.computeVaultAddress(
            marketProxy,
            address(kuruAmmVaultImpl),
            false
        );
        KuruAMMVault vaultUSDC = KuruAMMVault(payable(vaultAddr));

        usdc.mint(address(this), 1000 * 1e6);
        ausd.mint(address(this), 1000 * 1e6);
        usdc.approve(address(vaultUSDC), type(uint256).max);
        ausd.approve(address(vaultUSDC), type(uint256).max);
        vaultUSDC.deposit(1e6, 1e6, address(this));

        ArbitrageKuruUniswap arbBotUSDC = new ArbitrageKuruUniswap(
            address(manager),
            address(obUSDC),
            address(usdc),
            address(ausd),
            address(this)
        );

        // Fund Bot with BASE (USDC) for reverse arb?
        // Reverse Arb: Sell Uni(High), Buy Kuru (Low).
        // Sell Uni: Base Input -> Quote Output. (If Base < Quote, ZeroForOne=True, Input Base=0).
        // Wait, Uni V4 swap input depends on direction.
        // Reverse Arb: Sell Base on Uni?
        // Price > Ask. Uni Price High.
        // Yes. Sell Base on Uni -> Get Quote. Buy Base on Kuru with Quote.
        // So we need Base inventory to start? No, Arb calc usually assumes we have Quote?

        // Wait, Reverse logic in Contract:
        // "Sell Uniswap (High)". "Input: Token1 (Debt). Output: Token0 (Credit)." (If Base=0)
        // If Base=0 (USDC < AUSD?).
        // Let's assume USDC < AUSD (75 < ef). USDC=0.
        // Sell Uni (Swap 1->0). Input Quote (1). Output Base (0).
        // Wait. High Price means Price > Ask.
        // Price = Q/B. High Price = More Quote per Base.
        // Sell Base! -> Get MORE Quote.
        // Swap 0->1. Input Base. Output Quote.
        // So we need BASE inventory?
        // Or do we flash loan?
        // Our contract uses `PM.take`.
        // If Swap(0->1) (Sell Base).
        // Delta0 (Base) is negative (Input/Debt).
        // We pay Base to Uni.
        // Delta1 (Quote) is positive (Output/Credit).
        // We Get Quote from Uni.
        // We use Quote to BUY Base on Kuru.
        // So we start with FLASH swap.
        // Do we need initial inventory? No. V4 Flash allows pay later.
        // But we need to pay Base debt at end.
        // Kuru Buy gives us Base.
        // We use that Base to pay Uni.
        // So we don't need initial inventory if profitable.

        // So funding bot with AUSD (Quote) is fine? Or nothing is fine?
        // We might need gas/fees?

        // Setup Kuru Sell Order? No, Buy Kuru (Low).
        // So Kuru needs ASK order (someone selling Cheap).
        // Add Sell Order @ 1.0.
        usdc.mint(address(this), 1000000 * 1e6);
        usdc.approve(address(obUSDC), type(uint256).max);
        obUSDC.addSellOrder(10000000, 500 * 1e6, false);

        // Uni Price 1.1. High.
        // Sqrt(1.1) ~= 1.048.
        // 1.048 * 2^96 = 8.3e22.
        uint160 sqrtPrice11 = 83000000000000000000000;

        Currency c0 = address(usdc) < address(ausd)
            ? Currency.wrap(address(usdc))
            : Currency.wrap(address(ausd));
        Currency c1 = address(usdc) < address(ausd)
            ? Currency.wrap(address(ausd))
            : Currency.wrap(address(usdc));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        // Dynamic Start Price:
        // Reverse Arb needs Base Expensive on Uni.
        // If Base=0 (P=Q/B). 1.11 (High).
        // If Base=1 (P=B/Q). 0.9 (Inverse High).
        uint160 initialSqrtPrice;
        if (address(usdc) < address(ausd)) {
            initialSqrtPrice = 83400000000000000000000000000; // 1.11
        } else {
            initialSqrtPrice = 75100000000000000000000000000; // 0.9
        }
        manager.initialize(key, initialSqrtPrice);

        // Approve Routers for USDC/AUSD
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(swapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -300000,
                tickUpper: 300000,
                liquidityDelta: 1e15,
                salt: 0
            }),
            ZERO_BYTES
        );

        // Execute
        (bool profitable, , , , , , , ) = arbBotUSDC.calculateProfit();
        assertTrue(profitable, "Should be profitable");

        bool executed = arbBotUSDC.execute();
        assertTrue(executed, "Execution failed");
    }
}
