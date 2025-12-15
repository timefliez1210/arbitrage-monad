//! Experimental monadNewHeads arbitrage bot for Monad
//! 
//! Uses dynamic signing with in-memory nonce tracking for flexible priority fees.
//! Optimized for low-latency execution with connection pooling and parallel broadcasts.

mod config;

use alloy::{
    network::EthereumWallet,
    primitives::Address,
    providers::{Provider, ProviderBuilder, RootProvider},
    signers::local::PrivateKeySigner,
    sol,
    transports::http::{Client, Http},
};
use config::*;
use futures::StreamExt;
use std::str::FromStr;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::collections::HashMap;
use url::Url;
use tokio::sync::mpsc;

// Arbitrage contract interface
sol! {
    #[sol(rpc)]
    contract Arbitrage {
        function calculateProfit() external view returns (bool profitable, bool zeroForOne, bytes memory data, uint256 price1e18, uint256 bestBid, uint256 bestAsk, uint256 expectedProfit);
        function keeperProfit() external view returns (bool profitable, uint256 expectedProfit);
        function execute() external returns (bool);
    }
}

#[derive(Clone)]
struct ArbBot {
    address: Address,
    name: Arc<str>,  // Arc<str> avoids cloning in hot path
    tx_template: TxTemplate,  // Pre-computed tx fields for hot path
}

// Pre-computed transaction template - avoids repeated calldata encoding in hot path
#[derive(Clone)]
struct TxTemplate {
    to: Address,
    calldata: alloy::primitives::Bytes,  // Pre-encoded execute() call
    chain_id: u64,
    gas_limit: u128,
}

impl TxTemplate {
    fn new(bot_address: Address) -> Self {
        use alloy::sol_types::SolCall;
        let execute_call = Arbitrage::executeCall {};
        let calldata = alloy::primitives::Bytes::from(execute_call.abi_encode());
        
        Self {
            to: bot_address,
            calldata,
            chain_id: CHAIN_ID,
            gas_limit: GAS_LIMIT,
        }
    }
    
    fn build_with(&self, nonce: u64, priority_fee: u128) -> alloy::rpc::types::TransactionRequest {
        use alloy::network::TransactionBuilder;
        
        alloy::rpc::types::TransactionRequest::default()
            .with_to(self.to)
            .with_input(self.calldata.clone())
            .with_nonce(nonce)
            .with_chain_id(self.chain_id)
            .with_gas_limit(self.gas_limit)
            .with_max_fee_per_gas(gwei_to_wei(BASE_MAX_FEE_GWEI) + priority_fee)
            .with_max_priority_fee_per_gas(priority_fee)
    }
}

// Background receipt polling request (simplified for keeperProfit)
struct ReceiptRequest {
    tx_hash: alloy::primitives::B256,
    bot_name: Arc<str>,
    block_detected: u64,
    expected_profit: String,
    check_time: String,
    exec_time: String,
    receive_time: Instant,
}

fn format_wei(val: alloy::primitives::U256) -> String {
    let val_u128: u128 = val.try_into().unwrap_or(u128::MAX);
    let float_val = val_u128 as f64 / 1e18;                                                                                                                                                                                                                                                                         
    format!("{:.6}", float_val)
}

fn log_transaction(bot_name: &str, tx_hash: &str, block_detected: u64, block_executed: u64, 
    expected_profit: &str, check_time: &str, exec_time: &str, total_time: &str) {
    
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let block_diff = block_executed.saturating_sub(block_detected);
    
    let entry = format!(
        "| {} | {} | {} | {} | {} | Δ+{} | {} | {} | {} | {} |\n",
        timestamp, bot_name, tx_hash, block_detected, block_executed, block_diff,
        expected_profit, check_time, exec_time, total_time
    );
    
    let file_exists = std::path::Path::new(TX_LOG_FILE).exists();
    
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(TX_LOG_FILE)
        .expect("Failed to open transaction log file");
    
    if !file_exists {
        let header = "# Transaction Log (monadNewHeads + keeperProfit)\n\n| Timestamp | Bot | Tx Hash | Block Detected | Block Executed | Δ Blocks | Expected Profit | Check Time | Exec Time | Total Time |\n|-----------|-----|---------|----------------|----------------|----------|-----------------|------------|-----------|------------|\n";
        file.write_all(header.as_bytes()).expect("Failed to write header");
    }
    
    file.write_all(entry.as_bytes()).expect("Failed to write transaction log");
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenv::dotenv().ok();
    
    println!("╔════════════════════════════════════════════════════════════╗");
    println!("║   MONAD NEW HEADS BOT - Alloy Native WebSocket             ║");
    println!("╚════════════════════════════════════════════════════════════╝\n");
    
    let private_key = std::env::var("PRIVATE_KEY")?;
    
    // Load WebSocket URL from config (primary, then fallbacks)
    let ws_url = std::env::var(PRIMARY_WS_ENV)
        .or_else(|_| {
            for fallback in FALLBACK_WS_ENVS {
                if let Ok(url) = std::env::var(fallback) {
                    return Ok(url);
                }
            }
            Err(std::env::VarError::NotPresent)
        })?;
    
    let is_native_monad = ws_url.contains("monad.xyz") || ws_url.contains("monad-rpc");
    
    // Detect provider from URL for display purposes
    let provider_name = if is_native_monad { "Monad Native (monadNewHeads supported!)" }
        else if ws_url.contains("alchemy") { "Alchemy" }
        else if ws_url.contains("quiknode") || ws_url.contains("quicknode") { "QuickNode" }
        else if ws_url.contains("drpc") { "dRPC" }
        else if ws_url.contains("chainstack") { "Chainstack" }
        else if ws_url.contains("infura") { "Infura" }
        else if ws_url.contains("ankr") { "Ankr" }
        else { "Other" };
    
    println!("🔌 WebSocket: {} {}", provider_name, 
        if is_native_monad { "" } else { "(fallback to newHeads)" });
    
    // Build bots from config
    let bots: Vec<ArbBot> = get_bot_addresses()
        .into_iter()
        .map(|(addr, name)| ArbBot {
            address: addr,
            name: Arc::from(name),
            tx_template: TxTemplate::new(addr),
        })
        .collect();
    
    println!("🤖 Loaded {} bots from config", bots.len());
    for bot in &bots {
        println!("   • {} @ {:?}", bot.name, bot.address);
    }
    
    // Auto-reconnection loop
    let mut reconnect_count = 0u32;
    loop {
        reconnect_count += 1;
        if reconnect_count > 1 {
            println!("\n🔄 Reconnection attempt #{}", reconnect_count);
        }
        
        match run_monad_bot(bots.clone(), private_key.clone(), ws_url.clone()).await {
            Ok(_) => {
                println!("✅ Bot exited cleanly");
                break;
            }
            Err(e) => {
                println!("\n⚠️ Bot error: {:?}", e);
                println!("🔄 Reconnecting in 3 seconds...");
                tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
            }
        }
    }
    
    Ok(())
}

async fn run_monad_bot(bots: Vec<ArbBot>, private_key: String, ws_url: String) -> anyhow::Result<()> {
    let signer = PrivateKeySigner::from_str(&private_key)?;
    let wallet_address = signer.address();
    let wallet = EthereumWallet::from(signer);
    
    // Pre-create broadcast providers at startup (connection pooling - saves ~10-50ms per broadcast)
    let mut broadcast_providers: Vec<Arc<RootProvider<Http<Client>>>> = vec![];
    
    for (env_var, name) in BROADCAST_ENDPOINTS {
        if let Ok(url) = std::env::var(env_var) {
            if let Ok(parsed) = Url::parse(&url) {
                let provider = ProviderBuilder::new().on_http(parsed);
                broadcast_providers.push(Arc::new(provider));
                println!("📡 {} (pre-connected)", name);
            }
        }
    }
    println!("🔗 Broadcast providers: {} (connection pooled)", broadcast_providers.len());
    
    let broadcast_providers = Arc::new(broadcast_providers);
    let wallet_arc = Arc::new(wallet.clone());
    
    // Create HTTP provider for RPC calls
    let rpc_url = std::env::var(PRIMARY_HTTPS_ENV)?;
    let http_provider = ProviderBuilder::new()
        .with_recommended_fillers()
        .wallet(wallet.clone())
        .on_http(Url::parse(&rpc_url)?);
    let http_provider = Arc::new(http_provider);
    
    // ========== RPC HEALTH CHECK ==========
    // Test RPC latency at startup to catch slow endpoints early
    println!("\n🔍 Testing RPC latency ({})...", PRIMARY_HTTPS_ENV);
    let health_provider = ProviderBuilder::new().on_http(Url::parse(&rpc_url)?);
    let mut latencies: Vec<u128> = vec![];
    for i in 1..=3 {
        let start = Instant::now();
        let _ = health_provider.get_block_number().await?;
        let elapsed = start.elapsed().as_millis();
        latencies.push(elapsed);
        print!("   Test {}: {}ms", i, elapsed);
        if elapsed > 100 { print!(" ⚠️"); }
        println!();
    }
    let avg_latency = latencies.iter().sum::<u128>() / latencies.len() as u128;
    if avg_latency > 100 {
        println!("⚠️  WARNING: RPC latency is HIGH ({}ms avg) - consider using a faster endpoint!", avg_latency);
        println!("   Recommended: QUICKNODE_HTTPS (~35-50ms)");
    } else if avg_latency > 50 {
        println!("⚡ RPC latency OK: {}ms avg", avg_latency);
    } else {
        println!("🚀 RPC latency EXCELLENT: {}ms avg", avg_latency);
    }
    
    // Test pending state access (critical for monadNewHeads strategy)
    println!("\n🔍 Testing pending state access...");
    use alloy::eips::BlockNumberOrTag;
    let latest_block = health_provider.get_block_number().await?;
    let pending_result = health_provider.get_block_by_number(BlockNumberOrTag::Pending, false).await;
    match pending_result {
        Ok(Some(pending_block)) => {
            if let Some(pending_num) = pending_block.header.number {
                let diff = pending_num.saturating_sub(latest_block);
                if diff >= 1 {
                    println!("✅ Pending state: Block {} (latest: {}, ahead by {})", pending_num, latest_block, diff);
                    println!("   Provider has fresh consensus state!");
                } else {
                    println!("⚡ Pending state: Block {} (same as latest {})", pending_num, latest_block);
                    println!("   Provider may not have real-time consensus - still usable");
                }
            } else {
                println!("⚠️  Pending block has no number - unusual response");
            }
        }
        Ok(None) => {
            println!("⚠️  WARNING: Pending block returned None - provider may not support pending queries");
        }
        Err(e) => {
            println!("⚠️  WARNING: Failed to query pending state: {:?}", e);
            println!("   This may affect performance with monadNewHeads strategy");
        }
    }
    println!();
    
    // Atomic nonce tracking - single shared nonce for all bots (same wallet)
    let initial_nonce = {
        let provider = ProviderBuilder::new().on_http(Url::parse(&rpc_url)?);
        provider.get_transaction_count(wallet_address).await?
    };
    let shared_nonce = Arc::new(AtomicU64::new(initial_nonce));
    
    println!("👛 Wallet: {:?}", wallet_address);
    println!("🔢 Initial nonce: {}", initial_nonce);
    println!("⚡ Dynamic signing + connection pooling enabled");
    
    // Background receipt polling - moves receipt fetching OFF the critical path
    let (receipt_tx, mut receipt_rx) = mpsc::channel::<ReceiptRequest>(100);
    let receipt_provider = http_provider.clone();
    tokio::spawn(async move {
        while let Some(req) = receipt_rx.recv().await {
            let provider = receipt_provider.clone();
            let bot_name = req.bot_name.clone();
            
            tokio::spawn(async move {
                let mut attempts = 0;
                while attempts < 10 {
                    tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;
                    if let Ok(Some(receipt)) = provider.get_transaction_receipt(req.tx_hash).await {
                        let block_executed = receipt.block_number.unwrap_or(0);
                        let total_elapsed = req.receive_time.elapsed();
                        let block_diff = block_executed.saturating_sub(req.block_detected);
                        
                        println!("[{}] 📦 Confirmed block {} | Proposed: {} | Δ+{}", 
                            bot_name, block_executed, req.block_detected, block_diff);
                        
                        log_transaction(
                            &bot_name, &format!("{:?}", req.tx_hash), req.block_detected, block_executed,
                            &req.expected_profit, &req.check_time, &req.exec_time, &format!("{:?}", total_elapsed),
                        );
                        break;
                    }
                    attempts += 1;
                }
            });
        }
    });
    
    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    
    // ========== RAW WEBSOCKET FOR monadNewHeads ==========
    use tokio_tungstenite::{connect_async, tungstenite::Message};
    use futures::SinkExt;
    
    println!("\n🔌 Connecting via raw WebSocket for monadNewHeads...");
    
    let (mut ws_stream, _) = connect_async(&ws_url).await?;
    println!("✅ Raw WebSocket connected");
    
    // Subscribe to monadNewHeads (Monad-specific early block notification)
    let subscribe_msg = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_subscribe",
        "params": ["monadNewHeads", {}]
    });
    
    ws_stream.send(Message::Text(subscribe_msg.to_string())).await?;
    println!("📤 Sent monadNewHeads subscription request");
    
    // Wait for subscription confirmation
    let mut sub_type = "UNKNOWN";
    if let Some(Ok(msg)) = ws_stream.next().await {
        if let Message::Text(text) = msg {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(result) = json.get("result") {
                    if result.as_str().is_some() {
                        sub_type = "MONAD_NEW_HEADS";
                        println!("🚀 monadNewHeads subscription confirmed! ID: {}", result);
                    }
                }
                if let Some(error) = json.get("error") {
                    println!("⚠️ monadNewHeads failed: {:?}", error);
                    println!("📦 Falling back to standard newHeads...");
                    
                    // Subscribe to standard newHeads instead
                    let fallback_msg = serde_json::json!({
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "eth_subscribe",
                        "params": ["newHeads"]
                    });
                    ws_stream.send(Message::Text(fallback_msg.to_string())).await?;
                    
                    if let Some(Ok(msg2)) = ws_stream.next().await {
                        if let Message::Text(text2) = msg2 {
                            if let Ok(json2) = serde_json::from_str::<serde_json::Value>(&text2) {
                                if let Some(result2) = json2.get("result") {
                                    sub_type = "STD_NEW_HEADS";
                                    println!("✅ Standard newHeads subscription confirmed! ID: {}", result2);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    println!("✅ Subscription type: {}\n", sub_type);
    println!("🎯 Listening for block notifications...\n");
    
    // Track seen blocks to deduplicate (some providers send multiple notifications per block)
    let mut seen_blocks: std::collections::HashSet<u64> = std::collections::HashSet::new();
    let max_seen_history = 20;
    
    // Per-bot cooldown tracking: last block each bot bid on
    let last_bid_block: Arc<tokio::sync::RwLock<HashMap<Address, u64>>> = 
        Arc::new(tokio::sync::RwLock::new(HashMap::new()));
    
    if COOLDOWN_BLOCKS > 0 {
        println!("🧊 Cooldown enabled: {} blocks after each bid", COOLDOWN_BLOCKS);
    } else {
        println!("⚡ Cooldown disabled (volatility mode)");
    }
    
    while let Some(msg_result) = ws_stream.next().await {
        match msg_result {
            Ok(Message::Text(text)) => {
                // Parse the notification
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
                    // Check if it's a subscription notification
                    if json.get("method") == Some(&serde_json::json!("eth_subscription")) {
                        if let Some(params) = json.get("params") {
                            if let Some(result) = params.get("result") {
                                // For monadNewHeads: only act on "Proposed" state (earliest notification)
                                // For standard newHeads: commitState won't exist, so process all blocks
                                let commit_state = result.get("commitState")
                                    .and_then(|s| s.as_str());
                                
                                // Skip if monadNewHeads and not "Proposed" (wait for earliest signal)
                                // But process if standard newHeads (commit_state is None)
                                if let Some(state) = commit_state {
                                    if state != "Proposed" {
                                        continue;  // monadNewHeads: skip non-Proposed states
                                    }
                                }
                                // If commit_state is None, it's standard newHeads - process it!
                                
                                // Extract block number (handle hex format)
                                let block_num = if let Some(num_str) = result.get("number").and_then(|n| n.as_str()) {
                                    u64::from_str_radix(num_str.trim_start_matches("0x"), 16).unwrap_or(0)
                                } else {
                                    continue;
                                };
                                
                                // Deduplicate (shouldn't be needed now with Proposed filter, but safety)
                                if seen_blocks.contains(&block_num) {
                                    continue;
                                }
                                seen_blocks.insert(block_num);
                                
                                // Prune old entries
                                if seen_blocks.len() > max_seen_history {
                                    if let Some(&min_block) = seen_blocks.iter().min() {
                                        seen_blocks.remove(&min_block);
                                    }
                                }
                                
                                let receive_time = Instant::now();
                                let now_unix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
                                
                                // Extract timestamp
                                let block_timestamp = if let Some(ts_str) = result.get("timestamp").and_then(|t| t.as_str()) {
                                    u64::from_str_radix(ts_str.trim_start_matches("0x"), 16).unwrap_or(0)
                                } else {
                                    0
                                };
                                
                                let latency = now_unix.saturating_sub(block_timestamp);
                                
                                println!("\n══════════════════════════════════════════════════════════");
                                println!("🚀 PROPOSED Block #{} | Latency: {}s | Querying PENDING!", block_num, latency);
                                
                                // Process bots
                                for bot in &bots {
                                    // Check cooldown - skip if bot bid recently
                                    if COOLDOWN_BLOCKS > 0 {
                                        let last_bid = last_bid_block.read().await;
                                        if let Some(&last_block) = last_bid.get(&bot.address) {
                                            if block_num <= last_block + COOLDOWN_BLOCKS {
                                                // Still in cooldown, skip this bot
                                                continue;
                                            }
                                        }
                                    }
                                    
                                    // IMMEDIATELY mark this bot as "bidding" on this block
                                    // This prevents race condition where multiple blocks spawn tasks
                                    // before the first task finishes and updates cooldown
                                    if COOLDOWN_BLOCKS > 0 {
                                        let mut last_bid = last_bid_block.write().await;
                                        last_bid.insert(bot.address, block_num);
                                    }
                                    
                                    let contract = Arbitrage::new(bot.address, (*http_provider).clone());
                                    let bot_name = bot.name.clone();
                                    let tx_template = bot.tx_template.clone();  // Pre-computed tx template
                                    let receive_time_clone = receive_time;
                                    let block_num_clone = block_num;
                                    let broadcast_providers_clone = broadcast_providers.clone();
                                    let nonce_clone = shared_nonce.clone();
                                    let wallet_clone = wallet_arc.clone();
                                    let receipt_tx_clone = receipt_tx.clone();
                                    
                                    tokio::spawn(async move {
                                        let check_start = Instant::now();
                                        
                                        // Use optimized keeperProfit() - returns only (bool, uint256)
                                        // 10-tick depth vs 50, minimal return payload
                                        use alloy::eips::BlockNumberOrTag;
                                        let result = contract.keeperProfit()
                                            .block(BlockNumberOrTag::Pending.into())
                                            .call()
                                            .await;
                                        let check_elapsed = check_start.elapsed();
                                        
                                        match result {
                                            Ok(profit_data) => {
                                                if profit_data.profitable {
                                                    println!("[{}] 🎯 PROFITABLE! Block {} Profit: {} (check: {:?})", 
                                                        bot_name, block_num_clone, format_wei(profit_data.expectedProfit), check_elapsed);
                                                    
                                                    let exec_start = Instant::now();
                                                    
                                                    // Use pre-computed template - only fill in nonce + priority fee
                                                    use alloy::eips::eip2718::Encodable2718;
                                                    use alloy::network::TransactionBuilder;
                                                    
                                                    // Atomically get and increment nonce
                                                    let current_nonce = nonce_clone.fetch_add(1, Ordering::SeqCst);
                                                    
                                                    // Calculate dynamic priority fee based on profit
                                                    let profit_u128: u128 = profit_data.expectedProfit.try_into().unwrap_or(0);
                                                    let priority_fee = calculate_priority_fee(profit_u128);
                                                    let priority_gwei = priority_fee / 1_000_000_000;
                                                    
                                                    // DEBUG: Show priority calculation
                                                    println!("[{}] 💰 Raw profit: {} | Priority: {} gwei", 
                                                        bot_name, profit_u128, priority_gwei);
                                                    
                                                    // Build tx from template - avoids repeated abi_encode() in hot path!
                                                    let tx_request = tx_template.build_with(current_nonce, priority_fee);
                                                    
                                                    let tx_envelope = match tx_request.build(&*wallet_clone).await {
                                                        Ok(e) => e,
                                                        Err(err) => {
                                                            println!("[{}] ⚠️ Failed to sign tx: {:?}", bot_name, err);
                                                            return;
                                                        }
                                                    };
                                                    
                                                    // Pre-allocate vector for raw tx (avoids reallocation)
                                                    let mut raw_tx_vec = Vec::with_capacity(512);
                                                    tx_envelope.encode_2718(&mut raw_tx_vec);
                                                    let raw_tx = alloy::primitives::Bytes::from(raw_tx_vec);
                                                    let tx_hash = *tx_envelope.tx_hash();
                                                    
                                                    println!("[{}] ⚡ Signed tx nonce={} priority={}gwei (sign: {:?})", 
                                                        bot_name, current_nonce, priority_gwei, exec_start.elapsed());
                                                    
                                                    // Fire-and-forget broadcasts - DO NOT BLOCK the critical path
                                                    // Logs will still print from background task for benchmarking
                                                    let bot_name_log = bot_name.clone();
                                                    let bot_name_receipt = bot_name.clone(); // For receipt request
                                                    let provider_count = broadcast_providers_clone.len();
                                                    tokio::spawn(async move {
                                                        let broadcast_futures: Vec<_> = broadcast_providers_clone.iter().enumerate()
                                                            .map(|(i, provider)| {
                                                                let p = provider.clone();
                                                                let tx = raw_tx.clone();
                                                                let name = bot_name.clone();
                                                                let prio = priority_gwei;
                                                                async move {
                                                                    match p.send_raw_transaction(&tx).await {
                                                                        Ok(_) => println!("[{}] 📡 #{} ✓ ({}gwei)", name, i + 1, prio),
                                                                        Err(_) => {}
                                                                    }
                                                                }
                                                            })
                                                            .collect();
                                                        
                                                        futures::future::join_all(broadcast_futures).await;
                                                        println!("[{}] 📡 All {} broadcasts complete", bot_name, provider_count);
                                                    });
                                                    
                                                    let total_exec = exec_start.elapsed();
                                                    println!("[{}] 🚀 Tx dispatched to background | Sign+Dispatch: {:?}", 
                                                        bot_name_log, total_exec);
                                                    
                                                    // Cooldown already recorded before spawning task
                                                    
                                                    // Send receipt request to background worker (OFF critical path!)
                                                    let _ = receipt_tx_clone.send(ReceiptRequest {
                                                        tx_hash,
                                                        bot_name: bot_name_receipt,
                                                        block_detected: block_num_clone,
                                                        expected_profit: format_wei(profit_data.expectedProfit),
                                                        check_time: format!("{:?}", check_elapsed),
                                                        exec_time: format!("{:?}", total_exec),
                                                        receive_time: receive_time_clone,
                                                    }).await;
                                                }
                                            }
                                            Err(_e) => {
                                                // Pending query failed - spawn async retry (non-blocking!)
                                                let contract_retry = contract.clone();
                                                let bot_name_retry = bot_name.clone();
                                                let tx_template_retry = tx_template.clone();  // Use template for retry too
                                                let broadcast_providers_retry = broadcast_providers_clone.clone();
                                                let nonce_retry = nonce_clone.clone();
                                                let wallet_retry = wallet_clone.clone();
                                                
                                                tokio::spawn(async move {
                                                    // Wait briefly and retry pending
                                                    tokio::time::sleep(tokio::time::Duration::from_millis(30)).await;
                                                    
                                                    let retry_result = contract_retry.calculateProfit()
                                                        .block(BlockNumberOrTag::Pending.into())
                                                        .call()
                                                        .await;
                                                    
                                                    if let Ok(profit_data) = retry_result {
                                                        if profit_data.profitable {
                                                            println!("[{}] 🎯 PENDING (retry) block {} Profit: {}", 
                                                                bot_name_retry, block_num_clone, format_wei(profit_data.expectedProfit));
                                                            
                                                            // Use template for retry - consistent with main path
                                                            use alloy::eips::eip2718::Encodable2718;
                                                            use alloy::network::TransactionBuilder;
                                                            
                                                            let current_nonce = nonce_retry.fetch_add(1, Ordering::SeqCst);
                                                            let profit_u128: u128 = profit_data.expectedProfit.try_into().unwrap_or(0);
                                                            let priority_fee = calculate_priority_fee(profit_u128);
                                                            let priority_gwei = priority_fee / 1_000_000_000;
                                                            
                                                            // Build from template
                                                            let tx_request = tx_template_retry.build_with(current_nonce, priority_fee);
                                                            
                                                            if let Ok(tx_envelope) = tx_request.build(&*wallet_retry).await {
                                                                let mut raw_tx_vec = Vec::with_capacity(512);
                                                                tx_envelope.encode_2718(&mut raw_tx_vec);
                                                                let raw_tx = alloy::primitives::Bytes::from(raw_tx_vec);
                                                                
                                                                // Parallel broadcasts using pre-created providers
                                                                let broadcast_futures: Vec<_> = broadcast_providers_retry.iter().enumerate()
                                                                    .map(|(i, provider)| {
                                                                        let p = provider.clone();
                                                                        let tx = raw_tx.clone();
                                                                        let name = bot_name_retry.clone();
                                                                        async move {
                                                                            if let Ok(_) = p.send_raw_transaction(&tx).await {
                                                                                println!("[{}] 📡 #{} ✓ (retry, {}gwei)", name, i + 1, priority_gwei);
                                                                            }
                                                                        }
                                                                    })
                                                                    .collect();
                                                                
                                                                futures::future::join_all(broadcast_futures).await;
                                                            }
                                                        }
                                                    }
                                                    // Silent fail on retry
                                                });
                                            }
                                        }
                                    });
                                }
                                
                                println!("⚡ Spawned {} bot checks in {:?}", bots.len(), receive_time.elapsed());
                            }
                        }
                    }
                }
            }
            Ok(Message::Ping(data)) => {
                let _ = ws_stream.send(Message::Pong(data)).await;
            }
            Err(e) => {
                println!("⚠️ WebSocket error: {:?}", e);
                break;
            }
            _ => {}
        }
    }
    
    Ok(())
}
