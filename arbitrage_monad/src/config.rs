//! Configuration module for the Monad Arbitrage Keeper
//! 
//! Loads configuration from `config.toml` at startup for faster iteration.
//! No recompilation needed to change settings.

use alloy::primitives::Address;
use serde::Deserialize;
use std::fs;
use std::str::FromStr;
use std::sync::OnceLock;

// ═══════════════════════════════════════════════════════════════════════════════
// TOML CONFIGURATION STRUCTURES
// ═══════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Deserialize)]
pub struct Config {
    pub network: NetworkConfig,
    pub fees: FeesConfig,
    pub transaction: TransactionConfig,
    #[serde(rename = "broadcast")]
    pub broadcast_endpoints: Vec<BroadcastEndpoint>,
    pub bots: Vec<BotConfig>,
    pub logging: LoggingConfig,
}

#[derive(Debug, Deserialize)]
pub struct NetworkConfig {
    pub chain_id: u64,
    pub primary_ws_env: String,
    #[serde(default)]
    pub fallback_ws_envs: Vec<String>,
    #[serde(default = "default_true")]
    pub use_monad_new_heads: bool,
    pub primary_https_env: String,
}

#[derive(Debug, Deserialize)]
pub struct FeesConfig {
    pub base_priority_gwei: u64,
    pub max_priority_gwei: u64,
    pub base_max_fee_gwei: u64,
    pub min_profit_threshold: u64,
    pub profit_scaling_percent: u64,
}

#[derive(Debug, Deserialize)]
pub struct TransactionConfig {
    pub gas_limit: u64,
    #[serde(default)]
    pub cooldown_blocks: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct BroadcastEndpoint {
    pub env: String,
    pub name: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct BotConfig {
    pub address: String,
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct LoggingConfig {
    pub tx_log_file: String,
}

fn default_true() -> bool {
    true
}

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBAL CONFIG (Loaded once at startup)
// ═══════════════════════════════════════════════════════════════════════════════

static CONFIG: OnceLock<Config> = OnceLock::new();

/// Load config from config.toml. Call once at startup.
pub fn load_config() -> anyhow::Result<&'static Config> {
    let config_path = "config.toml";
    let content = fs::read_to_string(config_path)
        .map_err(|e| anyhow::anyhow!("Failed to read {}: {}", config_path, e))?;
    
    let config: Config = toml::from_str(&content)
        .map_err(|e| anyhow::anyhow!("Failed to parse {}: {}", config_path, e))?;
    
    // Store in global. If already set (shouldn't happen), just return the existing one.
    let _ = CONFIG.set(config);
    
    Ok(CONFIG.get().unwrap())
}

/// Get already loaded config. Panics if not yet loaded.
pub fn config() -> &'static Config {
    CONFIG.get().expect("Config not loaded. Call load_config() first.")
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Convert gwei to wei
#[inline(always)]
pub const fn gwei_to_wei(gwei: u128) -> u128 {
    gwei * 1_000_000_000
}

/// Calculate dynamic priority fee based on profit
pub fn calculate_priority_fee(cfg: &Config, profit_wei: u128) -> u128 {
    let base = gwei_to_wei(cfg.fees.base_priority_gwei as u128);
    let max = gwei_to_wei(cfg.fees.max_priority_gwei as u128);
    
    if profit_wei <= cfg.fees.min_profit_threshold as u128 {
        return base;
    }
    
    // Calculate priority fee: (profit * scaling%) / gas_limit
    let profit_as_gas_price = profit_wei * (cfg.fees.profit_scaling_percent as u128) / 100 / (cfg.transaction.gas_limit as u128);
    
    std::cmp::min(base + profit_as_gas_price, max)
}

/// Parse bot addresses from config
pub fn get_bot_addresses(cfg: &Config) -> Vec<(Address, String)> {
    cfg.bots
        .iter()
        .filter_map(|bot| {
            Address::from_str(&bot.address).ok().map(|a| (a, bot.name.clone()))
        })
        .collect()
}
