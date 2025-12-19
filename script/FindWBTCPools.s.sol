// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract FindWBTCPools is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant PM_ADDRESS = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    function run() public view {
        IPoolManager pm = IPoolManager(PM_ADDRESS);

        // Try different tickSpacing values for MON/WBTC (0.05% fee = 500)
        console.log("=== Searching for MON/WBTC Pool (fee 500) ===");

        int24[5] memory tickSpacings = [
            int24(1),
            int24(10),
            int24(60),
            int24(100),
            int24(200)
        ];

        for (uint i = 0; i < tickSpacings.length; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(0)), // MON (native)
                currency1: Currency.wrap(WBTC),
                fee: 500,
                tickSpacing: tickSpacings[i],
                hooks: IHooks(address(0))
            });

            PoolId id = key.toId();
            (uint160 sqrtPrice, int24 tick, , ) = pm.getSlot0(id);

            if (sqrtPrice > 0) {
                console.log(
                    "FOUND MON/WBTC with tickSpacing:",
                    uint24(tickSpacings[i])
                );
                console.log("  sqrtPriceX96:", sqrtPrice);
                console.log("  tick:", tick);
                console.log("  poolId:");
                console.logBytes32(PoolId.unwrap(id));
            }
        }

        // Try different tickSpacing values for WBTC/AUSD (0.05% fee = 500)
        // Note: Currency order matters - lower address first
        console.log("\n=== Searching for WBTC/AUSD Pool (fee 500) ===");

        for (uint i = 0; i < tickSpacings.length; i++) {
            // WBTC address > AUSD address, so AUSD is currency0
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(AUSD),
                currency1: Currency.wrap(WBTC),
                fee: 500,
                tickSpacing: tickSpacings[i],
                hooks: IHooks(address(0))
            });

            PoolId id = key.toId();
            (uint160 sqrtPrice, int24 tick, , ) = pm.getSlot0(id);

            if (sqrtPrice > 0) {
                console.log(
                    "FOUND AUSD/WBTC with tickSpacing:",
                    uint24(tickSpacings[i])
                );
                console.log("  sqrtPriceX96:", sqrtPrice);
                console.log("  tick:", tick);
                console.log("  poolId:");
                console.logBytes32(PoolId.unwrap(id));
            }
        }

        // Also check for 0.6% fee tier (6000)
        console.log("\n=== Searching for MON/WBTC Pool (fee 6000 = 0.6%) ===");

        for (uint i = 0; i < tickSpacings.length; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(WBTC),
                fee: 6000,
                tickSpacing: tickSpacings[i],
                hooks: IHooks(address(0))
            });

            PoolId id = key.toId();
            (uint160 sqrtPrice, int24 tick, , ) = pm.getSlot0(id);

            if (sqrtPrice > 0) {
                console.log(
                    "FOUND MON/WBTC (0.6%) with tickSpacing:",
                    uint24(tickSpacings[i])
                );
                console.log("  sqrtPriceX96:", sqrtPrice);
                console.log("  tick:", tick);
            }
        }
    }
}
