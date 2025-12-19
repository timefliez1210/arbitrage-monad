// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitrageTriangleWBTC} from "../src/ArbitrageTriangleWBTC.sol";

contract DeployArbitrageTriangleWBTC is Script {
    function run() external {
        address profitWallet = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

        vm.startBroadcast();

        ArbitrageTriangleWBTC arb = new ArbitrageTriangleWBTC(profitWallet);

        console.log("ArbitrageTriangleWBTC deployed to:", address(arb));
        console.log("Owner/Profit recipient:", profitWallet);

        vm.stopBroadcast();
    }
}
