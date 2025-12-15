// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/ArbitrageUSDC.sol";

contract DeployArbitrageUSDC is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address poolManager = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
        address orderBook = 0x122C0D8683Cab344163fB73E28E741754257e3Fa; // MON/USDC
        address usdc = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
        address profitWallet = 0x774370b2BE82C1836A695d8653B5F9c4bb4985Fb;

        vm.startBroadcast(deployerPrivateKey);

        ArbitrageUSDC arb = new ArbitrageUSDC(
            poolManager,
            orderBook,
            usdc,
            profitWallet
        );
        console.log("ArbitrageUSDC deployed at:", address(arb));

        vm.stopBroadcast();
    }
}
