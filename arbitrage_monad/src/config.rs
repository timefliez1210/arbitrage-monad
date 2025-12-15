//! Configuration module for the Monad Arbitrage Keeper
//! 
//! Edit this file to change RPC endpoints, fee parameters, and bot settings.

use alloy::primitives::Address;
use std::str::FromStr;

// ═══════════════════════════════════════════════════════════════════════════════
// NETWORK CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Chain ID for the target network
pub const CHAIN_ID: u64 = 143;

/// Primary WebSocket endpoint for block subscriptions
/// Supports: Monad native (monadNewHeads), QuickNode, Alchemy, dRPC
// pub const PRIMARY_WS_ENV: &str = "QUICKNODE_WS";
pub const PRIMARY_WS_ENV: &str = "CHAINSTACK_WS";
// pub const PRIMARY_WS_ENV: &str = "DRPC_WS";

/// Fallback WebSocket endpoints (tried in order if primary fails)
pub const FALLBACK_WS_ENVS: &[&str] = &[
    "ALCHEMY_WEBSOCKET_API",
    "DRPC_WS",
];

/// Primary HTTPS endpoint for RPC calls (calculateProfit, nonce, etc.)
// pub const PRIMARY_HTTPS_ENV: &str = "QUICKNODE_HTTPS";
pub const PRIMARY_HTTPS_ENV: &str = "CHAINSTACK_HTTP";
// pub const PRIMARY_HTTPS_ENV: &str = "DRPC_HTTPS";
// pub const PRIMARY_HTTPS_ENV: &str = "INFURA_HTTPS_API";
// pub const PRIMARY_HTTPS_ENV: &str = "ALCHEMY_HTTPS_API";
// pub const PRIMARY_HTTPS_ENV: &str = "ANKR_HTTPS";
// pub const PRIMARY_HTTPS_ENV: &str = "DRPC_HTTPS";


/// Broadcast endpoints - transactions are sent to ALL of these in parallel
/// Format: (env_var_name, display_name)
pub const BROADCAST_ENDPOINTS: &[(&str, &str)] = &[
    ("QUICKNODE_HTTPS", "QuickNode"),
    ("INFURA_HTTPS_API", "Infura"),
    ("ALCHEMY_HTTPS_API", "Alchemy"),
    ("ANKR_HTTPS", "Ankr"),
    ("DRPC_HTTPS", "dRPC"),
    ("CHAINSTACK_HTTP", "Chainstack"),
];

// ═══════════════════════════════════════════════════════════════════════════════
// PRIORITY FEE CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Base priority fee in gwei (applied to all transactions)
pub const BASE_PRIORITY_GWEI: u128 = 30;

/// Maximum priority fee cap in gwei (prevents overpaying)
pub const MAX_PRIORITY_GWEI: u128 = 100;

/// Minimum profit threshold (in 18 decimals) before adding profit-based priority
/// 0.05 = 5 cents threshold
pub const MIN_PROFIT_THRESHOLD: u128 = 50_000_000_000_000_000;

/// Percentage of profit to add to priority fee (e.g., 2 = 2%)
pub const PROFIT_SCALING_PERCENT: u128 = 2;

/// Base max fee per gas in gwei (added to priority fee for max_fee_per_gas)
pub const BASE_MAX_FEE_GWEI: u128 = 100;

// ═══════════════════════════════════════════════════════════════════════════════
// TRANSACTION CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Gas limit for execute() transactions
pub const GAS_LIMIT: u128 = 3_000_000;

/// Cooldown: Skip checking a bot for N blocks after it broadcasts
/// Set to 0 to disable (useful for high volatility periods)
pub const COOLDOWN_BLOCKS: u64 = 2;

// ═══════════════════════════════════════════════════════════════════════════════
// BOT CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Bot contract addresses and names
/// Format: (address, name)  
/// Comment out bots to disable them
pub const BOTS: &[(&str, &str)] = &[
    ("0xc2e5ec965af80916eacfc28cae63e3bd85d195e1", "USDC-v5"),
    ("0x1ac3741941f8a4dfe99274d78826998b4b02e671", "AUSD-v5"),
    // ("0xbee8762143c3a9f26831981d4871862fa7134d01", "Triangle-v3"),
];

// ═══════════════════════════════════════════════════════════════════════════════
// LOGGING CONFIGURATION  
// ═══════════════════════════════════════════════════════════════════════════════

/// Transaction log file path
pub const TX_LOG_FILE: &str = "transactions_monad.md";

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Convert gwei to wei
pub const fn gwei_to_wei(gwei: u128) -> u128 {
    gwei * 1_000_000_000
}

/// Calculate dynamic priority fee based on profit
pub fn calculate_priority_fee(profit_wei: u128) -> u128 {
    let base = gwei_to_wei(BASE_PRIORITY_GWEI);
    let max = gwei_to_wei(MAX_PRIORITY_GWEI);
    
    if profit_wei <= MIN_PROFIT_THRESHOLD {
        return base;
    }
    
    // Calculate priority fee: (profit * scaling%) / gas_limit
    let profit_as_gas_price = profit_wei * PROFIT_SCALING_PERCENT / 100 / GAS_LIMIT;
    
    std::cmp::min(base + profit_as_gas_price, max)
}

/// Parse bot addresses from config
pub fn get_bot_addresses() -> Vec<(Address, &'static str)> {
    BOTS.iter()
        .filter_map(|(addr, name)| {
            Address::from_str(addr).ok().map(|a| (a, *name))
        })
        .collect()
}
