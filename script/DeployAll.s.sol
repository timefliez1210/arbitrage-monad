// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitrageAUSD} from "../src/ArbitrageAUSD.sol";
import {ArbitrageUSDC} from "../src/ArbitrageUSDC.sol";
import {ArbitrageGMON} from "../src/ArbitrageGMON.sol";
import {ArbitrageAUSDUSDC} from "../src/ArbitrageAUSDUSDC.sol";

/// @title DeployAll - Deploy all arbitrage contracts at once
/// @notice Deploys ArbitrageAUSD, ArbitrageUSDC, ArbitrageGMON, and ArbitrageAUSDUSDC
contract DeployAll is Script {
    // ============ ADDRESSES ============

    // Uniswap V4 Pool Manager
    address constant POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;

    // Kuru Orderbooks
    address constant OB_MON_AUSD = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;
    address constant OB_MON_USDC = 0x122C0D8683Cab344163fB73E28E741754257e3Fa;

    // Tokens
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    // Profit recipient (update this if needed)
    address constant PROFIT_WALLET = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

    // ============ DEPLOYED CONTRACTS ============

    ArbitrageAUSD public arbAUSD;
    ArbitrageUSDC public arbUSDC;
    ArbitrageGMON public arbGMON;
    ArbitrageAUSDUSDC public arbAUSDUSDC;

    function run() external {
        vm.startBroadcast();

        // Deploy ArbitrageAUSD (MON/AUSD via V4 + Kuru)
        arbAUSD = new ArbitrageAUSD(
            POOL_MANAGER,
            OB_MON_AUSD,
            AUSD,
            PROFIT_WALLET
        );
        console.log("ArbitrageAUSD deployed at:", address(arbAUSD));

        // Deploy ArbitrageUSDC (MON/USDC via V4 + Kuru)
        arbUSDC = new ArbitrageUSDC(
            POOL_MANAGER,
            OB_MON_USDC,
            USDC,
            PROFIT_WALLET
        );
        console.log("ArbitrageUSDC deployed at:", address(arbUSDC));

        // Deploy ArbitrageGMON (MON/gMON via V3 + Kuru)
        arbGMON = new ArbitrageGMON(PROFIT_WALLET);
        console.log("ArbitrageGMON deployed at:", address(arbGMON));

        // Deploy ArbitrageAUSDUSDC (AUSD/USDC via V4 + Kuru)
        arbAUSDUSDC = new ArbitrageAUSDUSDC(PROFIT_WALLET);
        console.log("ArbitrageAUSDUSDC deployed at:", address(arbAUSDUSDC));

        vm.stopBroadcast();

        // ============ SUMMARY ============
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Profit Wallet:", PROFIT_WALLET);
        console.log("");
        console.log("ARB_AUSD=", address(arbAUSD));
        console.log("ARB_USDC=", address(arbUSDC));
        console.log("ARB_GMON=", address(arbGMON));
        console.log("ARB_AUSD_USDC=", address(arbAUSDUSDC));
        console.log("=========================================\n");

        // Print in .env format for easy copy-paste
        console.log("# Add to .env:");
        console.log(
            string.concat("ARB_AUSD_ADDRESS=", vm.toString(address(arbAUSD)))
        );
        console.log(
            string.concat("ARB_USDC_ADDRESS=", vm.toString(address(arbUSDC)))
        );
        console.log(
            string.concat("ARB_GMON_ADDRESS=", vm.toString(address(arbGMON)))
        );
        console.log(
            string.concat(
                "ARB_AUSD_USDC_ADDRESS=",
                vm.toString(address(arbAUSDUSDC))
            )
        );
    }
}
