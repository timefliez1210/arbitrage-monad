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
import {OrderBook as OrderBookImpl} from "@kuru/contracts/OrderBook.sol"; // For clarity
import {IOrderBook} from "@kuru/contracts/interfaces/IOrderBook.sol";
import {Router} from "@kuru/contracts/Router.sol";
import {MarginAccount} from "@kuru/contracts/MarginAccount.sol";
import {KuruForwarder} from "@kuru/contracts/KuruForwarder.sol";
import {KuruAMMVault} from "@kuru/contracts/KuruAMMVault.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArbitrageAUSD} from "../src/ArbitrageAUSD.sol";
import {ArbitrageAUSDUSDC} from "../src/ArbitrageAUSDUSDC.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract LocalIntegrationTest is Deployers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MockERC20 ausd;
    MockERC20 usdc;

    // Kuru Ecosystem
    Router kuruRouter;
    MarginAccount marginAccount;
    OrderBookImpl orderBookImpl; // Renamed for clarity
    KuruAMMVault kuruAmmVaultImpl;
    KuruForwarder kuruForwarder;
    OrderBook orderBook; // The proxy
    KuruAMMVault vault; // New vault variable

    // Arbitrage Contracts
    ArbitrageAUSD arbAUSD;
    // Arbitrage arbUSDC; // Removed - Arbitrage.sol no longer exists
    ArbitrageAUSDUSDC arbAUSDUSDC;

    // Test params
    uint256 constant MON_PRICE_INITIAL = 1e18; // 1:1 for simplicity in vault?
    // Wait, test uses 1.0.

    function setUp() public virtual {
        // 1. Deploy Uniswap V4 Environment
        deployFreshManagerAndRouters();

        // 2. Deploy Tokens
        ausd = new MockERC20("AUSD", "AUSD", 6); // 6 decimals as per reality? Or 18? AUSD is usually 18.
        // Wait, AUSD in Arbitrage.sol is 18?
        // AUSD: 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a. likely 18 decimals.
        // USDC: 6 decimals.
        // Let's verify decimals from usage.
        // Arbitrage.sol: calculates profit with 1e18 scaling.
        // OrderBook.sol handles decimals.
        // I will assume AUSD is 18 decimals and USDC is 6 decimals.
        // Wait, ArbitrageAUSD.sol line 53: AUSD constant.
        // I need to mock these tokens at the constant addresses OR deploy contract with constructor args.
        // The contracts HARDCODE addresses. I must deploy my mocks to those addresses using `vm.etch`.

        address AUSD_ADDR = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        address USDC_ADDR = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

        MockERC20 realAUSD = new MockERC20("AUSD", "AUSD", 6);
        vm.etch(AUSD_ADDR, address(realAUSD).code);
        ausd = MockERC20(AUSD_ADDR);
        // Re-initialize state if needed (MockERC20 is stateless except balanced, but `etch` only copies code)
        // We need to set balance manually if `stdStore` or assume mapping layout matches.
        // Solmate MockERC20 uses std mapping.

        MockERC20 realUSDC = new MockERC20("USDC", "USDC", 6);
        vm.etch(USDC_ADDR, address(realUSDC).code);
        usdc = MockERC20(USDC_ADDR);

        // 3. Deploy Kuru Ecosystem
        // Kuru Forwarder
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

        // Router
        Router routerImpl = new Router();
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), "");
        kuruRouter = Router(payable(address(routerProxy)));

        // Margin Account
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

        // Implementations
        orderBookImpl = new OrderBookImpl(); // Use OrderBookImpl
        kuruAmmVaultImpl = new KuruAMMVault();

        // Initialize Router
        kuruRouter.initialize(
            address(this),
            address(marginAccount),
            address(orderBookImpl),
            address(kuruAmmVaultImpl),
            address(kuruForwarder)
        );

        // Create Market via Router
        address marketProxy = kuruRouter.deployProxy(
            IOrderBook.OrderBookType.NATIVE_IN_BASE,
            address(0), // MON
            address(ausd),
            1e11, // Size Precision (Matches ArbitrageAUSD.sol)
            1e7, // Price
            1, // Tick
            2e13, // Min Size (200 MON Raw, Prec 1e7)
            2e17, // Max Size (2M MON Raw, Prec 1e7)
            20, // Taker Fee
            0, // Maker Fee
            100 // Spread
        );
        orderBook = OrderBook(payable(marketProxy));

        // 4b. Get the Kuru Vault deployed by Router
        address vaultAddr = kuruRouter.computeVaultAddress(
            marketProxy,
            address(kuruAmmVaultImpl),
            false
        );
        vault = KuruAMMVault(payable(vaultAddr));

        // Vault is already initialized by Router.deployProxy logic (it calls _kuruAmmVault.initialize).
        // So we just need to deposit.

        // Approve Margin Account for Vault? KuruAMMVault calls safeApprove in initialize.

        // Fund Vault (Owner must deposit to init price)
        vm.deal(address(this), 1000 * 1e18);
        ausd.mint(address(this), 1000 * 1e6);
        ausd.approve(address(vault), type(uint256).max);

        // Deposit 1 MON, 1 AUSD => Price 1.0
        vault.deposit{value: 1e18}(1e18, 1e6, address(this));

        // Register market in MarginAccount manually since Router didn't do it for this address
        vm.prank(address(kuruRouter));
        // ArbitrageAUSD.sol: Fee 50. TickSpacing 1.
        // PoolKey: currency0=AUSD, currency1=USDC (Sorted?)
        // Contract sorts them.
        // AUSD: 0x00...
        // USDC: 0x75...
        // AUSD < USDC. So currency0 = AUSD.

        currency0 = Currency.wrap(address(0)); // MON
        currency1 = Currency.wrap(address(ausd)); // AUSD

        // Deploy Pool Manager at HARDCODED Address?
        // PM Address: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e
        address PM_ADDR = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;

        // We can't easily etch PoolManager because it has complex storage.
        // Better to use `Deployers` to deploy a fresh one, and then etch its code to PM_ADDR
        // AND copy all its storage?
        // Copying storage is expensive/impossible generic.

        // Hack: Deploy `ArbitrageAUSD` with constructor args allowing override?
        // The user wants to avoid changing the contract source too much.
        // BUT `ArbitrageAUSD.sol` works with SPECIFIC addresses.

        // If I can't etch PM state, I can't test against hardcoded PM.
        // Solution: Create a `TestArbitrageAUSD` that inherits `ArbitrageAUSD` and overrides `PM` and `OB`?
        // Problem: They are `constant` (not virtual/internal). Constants are inlined in bytecode.

        // **Strategy**:
        // Use `vm.etch` for PM as well. But managing storage is hard.
        // Actually, `Deployers` deploys `PoolManager` at some address.
        // If I use `vm.etch(PM_ADDR, address(manager).code)`, the code is there.
        // But the interactions (swap, modifyLiquidity) update storage at `PM_ADDR`.
        // So I can treat `PM_ADDR` as the REAL manager.
        // Initialize it?
        // `PoolManager` relies on `msg.sender` for initialization? No.
        // I need to call `initialize` on PM_ADDR?
        // `PoolManager` doesn't have an `initialize` function (it's in constructor).
        // So I must `etch` the code, AND `store` the valid state?
        // State: `owner`, `protocolFeeController`.

        // Alternative Strategy (Recommended for Hardcoded Addresses):
        // Deploy standard contracts to random addresses.
        // Then use `vm.etch` to put a "Redirect Proxy" or the actual code at the Hardcoded Address?
        // NO.

        // **Simplest Strategy**:
        // Temporarily modify `ArbitrageAUSD.sol` to accept Constructor Arguments for these addresses.
        // This is safe if we default them to the hardcoded values for verification.
        // OR:
        // Use `vm.startPrank` and other cheats? No.

        // Let's try `vm.etch` for PM logic.
        // 1. Deploy `PoolManager` via `new PoolManager(500000)`.
        // 2. Fetch code.
        // 3. `vm.etch(PM_ADDR, code)`.
        // 4. `PoolManager(PM_ADDR)` is now a fresh generic PM (storage 0).
        // 5. Initialize it? `PoolManager` sets owner in constructor. Storage slot 0.
        //    I can set storage slot 0 to `address(this)`.

        // PM_ADDR not needed if we pass manager to constructor.
        // We use the manager from deployFreshManagerAndRouters() called at start.

        /*
        // Setup PM at PM_ADDR
        deployFreshManager(); // sets `manager` variable.
        vm.etch(PM_ADDR, address(manager).code);

        // Reset `manager` to point to hardcoded address for `Deployers` helpers to work?
        // `Deployers` uses `manager` state variable.
        manager = IPoolManager(PM_ADDR);
        */

        // Set Owner of PM_ADDR (Slot 0 for Ownable? Check storage layout.. usually slot 0).
        // PoolManager inherits `ProtocolFees` -> `Owned`.
        // Solady Owned: slot 0? No, verify.
        // Actually `PoolManager` has `protocolFeeController`.

        // Let's assume default storage (0) is fine, or set initialization if needed.
        // `Deployers` helpers call `manager.initialize`.

        // 5. Deploy Arbitrage Contracts

        // Ensure a clean slate for prank
        try vm.stopPrank() {} catch {}
        vm.startPrank(address(this));
        arbAUSD = new ArbitrageAUSD(
            address(manager),
            address(orderBook),
            address(ausd),
            address(this)
        );

        // Fund Accounts
        // Mint Abundant AUSD and USDC to this contract
        // Deal Native ETH (MON)
        vm.deal(address(this), 100000 ether);
        ausd.mint(address(this), 100000 ether);
        ausd.mint(address(arbAUSD), 10000 * 1e6); // Capital for arb (10k AUSD)
        // No USDC needed

        // Approve Kuru Margin Account
        ausd.approve(address(marginAccount), type(uint256).max);

        // Approve V4 Routers
        ausd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ausd.approve(address(swapRouter), type(uint256).max);

        // Deposit into Margin Account for "this" (User Acting as Counterparty)
        marginAccount.deposit(address(this), address(ausd), 500 * 1e6);
        marginAccount.deposit{value: 500 * 1e18}(
            address(this),
            address(0),
            500 * 1e18
        );
        vm.stopPrank();
    }

    function test_ForwardArbitrage() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));
        // Forward Arb: Buy on Uni (Low), Sell on Kuru (High).
        // 1. Setup Kuru (High Price). Bid 1.0 USDC/AUSD.
        // Price Precision: 1e7.
        // Price 1.0 = 1e7.
        // Size Precision: 1e6.
        // Size: 500 MON. Raw: 5e13. (5e13 * 1e7 = 5e20 = 500 MON)
        orderBook.addBuyOrder(10000000, 5e13, false);

        // Verify Kuru Price
        (uint256 bestBid, uint256 bestAsk) = orderBook.bestBidAsk();
        // bestBid should be 1000000000000000000
        assertEq(bestBid, 1e18);

        // 2. Setup Uni (Low Price). 0.9 USDC/AUSD.
        // Price 0.9. sqrtPrice.
        // 1 AUSD = 0.9 USDC. Sqrt(0.9) * 2^96.
        // sqrt(0.9) ~= 0.94868.
        // Adjusted for decimals: AUSD (6), MON (18). Raw Price factor 1e-12.
        // sqrt(1e-12) = 1e-6.
        // sqrtPrice = sqrt(0.9) * 1e-6 * 2^96
        uint160 sqrtPrice09 = 75100000000000000000000; // 7.51e22
        // Or use TickMath.
        // 0.9 is tick? log1.0001(0.9) ~= -1053.

        // Use Deployers helper
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 1, // MATCH ARBITRAGE CONTRACT
            hooks: IHooks(address(0))
        });
        PoolId id = PoolIdLibrary.toId(key);
        manager.initialize(key, sqrtPrice09);

        // Add Liquidity to Uni
        // Add enough to support the trade
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
        // Uni: 0.9. Kuru: 1.0.
        // Buy 0.9, Sell 1.0. Profit 0.1 per unit.

        (
            bool profitable,
            bool zeroForOne,
            bytes memory data,
            uint256 price1e18,
            uint256 bestBidOut,
            uint256 bestAskOut,
            uint256 expectedProfit
        ) = arbAUSD.calculateProfit();

        console.log("Profitable:", profitable);
        console.log("Expected Profit:", expectedProfit);
        console.log("Uni Price:", price1e18);
        console.log("ZeroForOne:", zeroForOne);

        assertTrue(profitable, "Should be profitable");
        assertEq(bestBidOut, 1e18, "Best Bid Mismatch");

        // 4. Execute
        uint256 balanceBefore = ausd.balanceOf(address(this)); // Profit recipient

        bool executed = arbAUSD.execute();
        assertTrue(executed, "Execution failed");

        uint256 balanceAfter = ausd.balanceOf(address(this));
        console.log("Profit Earned:", balanceAfter - balanceBefore);
        assertTrue(balanceAfter > balanceBefore, "No profit made");
    }

    function test_ReverseArbitrage() public {
        vm.deal(address(this), 1e30);
        vm.startPrank(address(this));
        // Reverse Arb: Buy on Kuru (Low), Sell on Uni (High).

        // 1. Setup Kuru (Low Price). Ask 1.0 USDC/AUSD.
        // 1. Setup Kuru (Low Price). Ask 1.0 USDC/AUSD.
        // Price: 1e7 (1.0). Size 500 MON (5e13 Raw, Prec 1e7).
        orderBook.addSellOrder(10000000, 5e13, false);

        // 2. Setup Uni (High Price). 1.1 USDC/AUSD.
        // 1.1 is tick? log1.0001(1.1) ~= 953.
        // Adjusted for decimals: 8.3e22
        uint160 sqrtPrice11 = 83000000000000000000000; // 8.30e22

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 1, // MATCH ARBITRAGE CONTRACT
            hooks: IHooks(address(0))
        });
        PoolId id = PoolIdLibrary.toId(key);
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

        (uint160 sqrtP, int24 t, , ) = manager.getSlot0(id);
        console.log("Init SqrtPrice:", sqrtP);
        console.log("Init Tick:", t);
        (uint256 kBid, uint256 kAsk) = orderBook.bestBidAsk();
        console.log("Kuru Best Ask:", kAsk);
        console.log("Kuru Best Bid:", kBid);

        // 3. Check Profitability
        (bool profitable, , , , , , uint256 expectedProfit) = arbAUSD
            .calculateProfit();

        assertTrue(profitable, "Should be profitable");

        // 4. Execute
        uint256 balanceBefore = address(this).balance;

        bool executed = arbAUSD.execute();
        assertTrue(executed, "Execution failed");

        uint256 balanceAfter = address(this).balance;
        console.log("Profit Earned:", balanceAfter - balanceBefore);
        assertTrue(balanceAfter > balanceBefore, "No profit made");
    }

    // Receive ETH
}
