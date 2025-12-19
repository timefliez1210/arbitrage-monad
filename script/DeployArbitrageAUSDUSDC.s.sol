// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitrageAUSDUSDC} from "../src/ArbitrageAUSDUSDC.sol";

contract DeployArbitrageAUSDUSDC is Script {
    function run() external {
        address profitWallet = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

        vm.startBroadcast();

        ArbitrageAUSDUSDC arb = new ArbitrageAUSDUSDC(profitWallet);

        console.log("ArbitrageAUSDUSDC deployed to:", address(arb));
        console.log("Owner/Profit recipient:", profitWallet);

        vm.stopBroadcast();
    }
}
