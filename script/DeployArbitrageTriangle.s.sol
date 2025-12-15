// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/ArbitrageTriangle.sol";

contract DeployArbitrageTriangle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Monad Mainnet Addresses
        address poolManager = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
        address orderBookAUSD = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3; // MON/AUSD
        address profitWallet = 0x774370b2BE82C1836A695d8653B5F9c4bb4985Fb;

        vm.startBroadcast(deployerPrivateKey);

        ArbitrageTriangle arb = new ArbitrageTriangle(
            poolManager,
            orderBookAUSD,
            profitWallet
        );
        console.log("ArbitrageTriangle deployed at:", address(arb));

        vm.stopBroadcast();
    }
}
