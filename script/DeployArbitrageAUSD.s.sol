// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/ArbitrageAUSD.sol";

contract DeployArbitrageAUSD is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address poolManager = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
        address orderBook = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;
        address ausd = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        address profitWallet = 0x774370b2BE82C1836A695d8653B5F9c4bb4985Fb;

        vm.startBroadcast(deployerPrivateKey);

        ArbitrageAUSD arb = new ArbitrageAUSD(
            poolManager,
            orderBook,
            ausd,
            profitWallet
        );
        console.log("ArbitrageAUSD deployed at:", address(arb));

        vm.stopBroadcast();
    }
}
