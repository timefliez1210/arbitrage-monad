// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitragePancakeAUSD} from "../src/ArbitragePancakeAUSD.sol";

contract RedeployAUSD is Script {
    function run() external {
        vm.startBroadcast();

        ArbitragePancakeAUSD arb = new ArbitragePancakeAUSD(
            0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b, // PCS AUSD/WMON
            0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3, // Kuru MON/AUSD
            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A, // WMON
            0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a, // AUSD
            0x0000000383dCfDc98cFda69dD8A9EEec239e35E1 // Profit wallet
        );

        console.log("ArbitragePancakeAUSD deployed at:", address(arb));
        vm.stopBroadcast();
    }
}
