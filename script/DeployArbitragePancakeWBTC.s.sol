// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ArbitragePancakeWBTC} from "../src/ArbitragePancakeWBTC.sol";

contract DeployArbitragePancakeWBTC is Script {
    address constant PROFIT_WALLET = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

    function run() external {
        vm.startBroadcast();

        ArbitragePancakeWBTC arb = new ArbitragePancakeWBTC(PROFIT_WALLET);
        console.log("ArbitragePancakeWBTC deployed at:", address(arb));

        vm.stopBroadcast();
    }
}
