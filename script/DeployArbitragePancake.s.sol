// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitragePancakeUSDC} from "../src/ArbitragePancakeUSDC.sol";
import {ArbitragePancakeAUSD} from "../src/ArbitragePancakeAUSD.sol";

/// @title DeployArbitragePancake - Deploy PancakeV3-Kuru arbitrage contracts
/// @dev Uses PCS swap callback as flash loan - no external flash loan source needed
contract DeployArbitragePancake is Script {
    // ============ ADDRESSES ============

    // PancakeV3 Pools
    address constant PCS_WMON_USDC = 0x63e48B725540A3Db24ACF6682a29f877808C53F2;
    address constant PCS_AUSD_WMON = 0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b;

    // Kuru Orderbooks
    address constant OB_MON_USDC = 0x122C0D8683Cab344163fB73E28E741754257e3Fa;
    address constant OB_MON_AUSD = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;

    // Tokens
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    // Profit recipient
    address constant PROFIT_WALLET = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

    // ============ DEPLOYED CONTRACTS ============
    ArbitragePancakeUSDC public arbPcsUsdc;
    ArbitragePancakeAUSD public arbPcsAusd;

    function run() external {
        vm.startBroadcast();

        // Deploy ArbitragePancakeUSDC (PCS WMON/USDC ↔ Kuru MON/USDC)
        arbPcsUsdc = new ArbitragePancakeUSDC(
            PCS_WMON_USDC,
            OB_MON_USDC,
            WMON,
            USDC,
            PROFIT_WALLET
        );
        console.log("ArbitragePancakeUSDC deployed at:", address(arbPcsUsdc));

        // Deploy ArbitragePancakeAUSD (PCS AUSD/WMON ↔ Kuru MON/AUSD)
        arbPcsAusd = new ArbitragePancakeAUSD(
            PCS_AUSD_WMON,
            OB_MON_AUSD,
            WMON,
            AUSD,
            PROFIT_WALLET
        );
        console.log("ArbitragePancakeAUSD deployed at:", address(arbPcsAusd));

        vm.stopBroadcast();

        // ============ SUMMARY ============
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Profit Wallet:", PROFIT_WALLET);
        console.log("");
        console.log("ARB_PCS_USDC=", address(arbPcsUsdc));
        console.log("ARB_PCS_AUSD=", address(arbPcsAusd));
        console.log("=========================================\n");
    }
}
