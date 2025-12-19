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
        address profitWallet = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

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
