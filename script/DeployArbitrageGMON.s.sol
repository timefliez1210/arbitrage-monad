// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ArbitrageGMON} from "../src/ArbitrageGMON.sol";

contract DeployArbitrageGMON is Script {
    function run() external {
        address profitWallet = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

        vm.startBroadcast();

        ArbitrageGMON arb = new ArbitrageGMON(profitWallet);

        console.log("ArbitrageGMON deployed to:", address(arb));
        console.log("Owner/Profit recipient:", profitWallet);
        console.log("V3 Pool (WMON/gMON):", address(arb.V3_POOL()));
        console.log("Kuru OB (MON/gMON):", address(arb.KURU_OB()));

        vm.stopBroadcast();
    }
}
