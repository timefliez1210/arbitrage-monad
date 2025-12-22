// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitragePcsUniAUSD} from "../src/ArbitragePcsUniAUSD.sol";
import {ArbitragePcsUniUSDC} from "../src/ArbitragePcsUniUSDC.sol";

/// @title DeployArbitragePcsUni - Deploy PCS↔Uni arbitrage contracts
contract DeployArbitragePcsUni is Script {
    // ============ ADDRESSES ============

    // PancakeV3 Pools
    address constant PCS_AUSD_WMON = 0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b;
    address constant PCS_WMON_USDC = 0x63e48B725540A3Db24ACF6682a29f877808C53F2;

    // Uniswap V4 PoolManager
    address constant POOL_MANAGER = 0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33;

    // Tokens
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    // Profit recipient
    address constant PROFIT_WALLET = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

    // ============ DEPLOYED CONTRACTS ============
    ArbitragePcsUniAUSD public arbPcsUniAusd;
    ArbitragePcsUniUSDC public arbPcsUniUsdc;

    function run() external {
        vm.startBroadcast();

        // Deploy ArbitragePcsUniAUSD (PCS AUSD/WMON ↔ Uni MON/AUSD)
        arbPcsUniAusd = new ArbitragePcsUniAUSD(
            PCS_AUSD_WMON,
            POOL_MANAGER,
            WMON,
            AUSD,
            PROFIT_WALLET
        );
        console.log("ArbitragePcsUniAUSD deployed at:", address(arbPcsUniAusd));

        // Deploy ArbitragePcsUniUSDC (PCS WMON/USDC ↔ Uni MON/USDC)
        arbPcsUniUsdc = new ArbitragePcsUniUSDC(
            PCS_WMON_USDC,
            POOL_MANAGER,
            WMON,
            USDC,
            PROFIT_WALLET
        );
        console.log("ArbitragePcsUniUSDC deployed at:", address(arbPcsUniUsdc));

        vm.stopBroadcast();

        // ============ SUMMARY ============
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Profit Wallet:", PROFIT_WALLET);
        console.log("");
        console.log("ARB_PCS_UNI_AUSD=", address(arbPcsUniAusd));
        console.log("ARB_PCS_UNI_USDC=", address(arbPcsUniUsdc));
        console.log("=========================================\n");
    }
}
