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
        address profitWallet = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

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
