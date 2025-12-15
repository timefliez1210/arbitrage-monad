// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract VerifyTicks is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant PM_ADDRESS = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    function run() public view {
        IPoolManager pm = IPoolManager(PM_ADDRESS);

        // MON/USDC pool
        PoolKey memory keyMonUsdc = PoolKey({
            currency0: Currency.wrap(address(0)), // MON
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        PoolId idMonUsdc = keyMonUsdc.toId();
        console.log("MON/USDC Pool ID:");
        console.logBytes32(PoolId.unwrap(idMonUsdc));

        (
            uint160 sqrtPrice1,
            int24 tick1,
            uint24 protocolFee1,
            uint24 lpFee1
        ) = pm.getSlot0(idMonUsdc);
        console.log("  sqrtPriceX96:", sqrtPrice1);
        console.log("  tick:", tick1);
        console.log("  protocolFee:", protocolFee1);
        console.log("  lpFee:", lpFee1);

        // MON/AUSD pool
        PoolKey memory keyMonAusd = PoolKey({
            currency0: Currency.wrap(address(0)), // MON
            currency1: Currency.wrap(AUSD),
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        PoolId idMonAusd = keyMonAusd.toId();
        console.log("\nMON/AUSD Pool ID:");
        console.logBytes32(PoolId.unwrap(idMonAusd));

        (uint160 sqrtPrice2, int24 tick2, , ) = pm.getSlot0(idMonAusd);
        console.log("  sqrtPriceX96:", sqrtPrice2);
        console.log("  tick:", tick2);

        // AUSD/USDC pool
        PoolKey memory keyAusdUsdc = PoolKey({
            currency0: Currency.wrap(AUSD),
            currency1: Currency.wrap(USDC),
            fee: 50,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        PoolId idAusdUsdc = keyAusdUsdc.toId();
        console.log("\nAUSD/USDC Pool ID:");
        console.logBytes32(PoolId.unwrap(idAusdUsdc));

        (uint160 sqrtPrice3, int24 tick3, , ) = pm.getSlot0(idAusdUsdc);
        console.log("  sqrtPriceX96:", sqrtPrice3);
        console.log("  tick:", tick3);
    }
}
