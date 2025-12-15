// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ArbitrageGMON} from "../src/ArbitrageGMON.sol";

contract DeployArbitrageGMON is Script {
    function run() external {
        // Profit recipient = deployer
        address profitRecipient = vm.envAddress("PROFIT_RECIPIENT");

        vm.startBroadcast();

        ArbitrageGMON arb = new ArbitrageGMON(profitRecipient);

        console.log("ArbitrageGMON deployed to:", address(arb));
        console.log("Profit recipient:", profitRecipient);

        vm.stopBroadcast();
    }
}
