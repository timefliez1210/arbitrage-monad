// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AddressConfig
/// @notice Centralized address configuration for all arbitrage contracts
/// @dev Import this into deployment scripts to ensure consistency
library AddressConfig {
    // ============ UNISWAP V4 ============
    address constant POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;

    // ============ PANCAKESWAP V3 POOLS ============
    address constant PCS_AUSD_WMON = 0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b; // token0=AUSD, token1=WMON
    address constant PCS_WMON_USDC = 0x63e48B725540A3Db24ACF6682a29f877808C53F2; // token0=WMON, token1=USDC

    // ============ KURU ORDERBOOKS ============
    address constant OB_MON_AUSD = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;
    address constant OB_MON_USDC = 0x122C0D8683Cab344163fB73E28E741754257e3Fa;

    // ============ TOKENS ============
    address constant MON = address(0); // Native token
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // ============ PROFIT WALLET ============
    address constant PROFIT_WALLET = 0x0000000383dCfDc98cFda69dD8A9EEec239e35E1;

    // ============ POOL TICK SPACING ============
    // MON/AUSD Uni V4: tickSpacing = 1
    // MON/USDC Uni V4: tickSpacing = 10
    int24 constant TICK_SPACING_AUSD = 1;
    int24 constant TICK_SPACING_USDC = 10;
}
