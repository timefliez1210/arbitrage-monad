//! Experimental monadNewHeads arbitrage bot for Monad
//! 
//! Uses single-socket architecture for state consistency.
//! The same WebSocket handles both block notifications AND RPC calls.
//! Optimized for low-latency execution with connection pooling and parallel broadcasts.

// Use jemalloc for better memory allocation in hot paths
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

mod config;

use alloy::{
    network::EthereumWallet,
    primitives::Address,
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
    sol,
};
use config::*;
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use std::str::FromStr;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use rustc_hash::{FxHashMap, FxHashSet};
use url::Url;
use tokio::sync::mpsc;
use tokio::net::TcpStream;
use tokio_tungstenite::{client_async, tungstenite::Message};
use tokio_native_tls::TlsConnector;

// ═══════════════════════════════════════════════════════════════════════════════
// ZERO-COPY COMBINED STRUCT (Safe Single-Pass for simd-json)
// simd-json modifies buffer in-place, so we MUST parse exactly once
// ═══════════════════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct MonadHeader<'a> {
    #[serde(borrow)]
    number: &'a str,
    #[serde(borrow)]
    timestamp: &'a str,
    #[serde(borrow, default)]
    commitState: Option<&'a str>,
}

#[derive(Deserialize)]
struct WsParams<'a> {
    #[serde(borrow)]
    result: MonadHeader<'a>,
}

// Combined message struct - handles BOTH notifications and responses in one parse
#[derive(Deserialize)]
struct CombinedMessage<'a> {
    // Notification fields
    #[serde(borrow, default)]
    method: Option<&'a str>,
    #[serde(borrow, default)]
    params: Option<WsParams<'a>>,
    
    // Response fields
    #[serde(default)]
    id: Option<u64>,
    #[serde(borrow, default)]
    result: Option<&'a str>,
    #[serde(default)]
    error: Option<simd_json::OwnedValue>,
}

// Arbitrage contract interface
sol! {
    #[sol(rpc)]
    contract Arbitrage {
        function calculateProfit() external view returns (bool profitable, bool zeroForOne, bytes memory data, uint256 price1e18, uint256 bestBid, uint256 bestAsk, uint256 expectedProfit);
        function keeperProfit() external view returns (bool profitable, uint256 expectedProfit);
        function execute() external returns (bool);
    }
}

// Multicall3 contract interface for batching RPC calls
sol! {
    #[sol(rpc)]
    contract Multicall3 {
        struct Call3 {
            address target;
            bool allowFailure;
            bytes callData;
        }
        
        struct Result {
            bool success;
            bytes returnData;
        }
        
        function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory returnData);
    }
}

// Multicall3 address (same on all EVM chains)
const MULTICALL3_ADDRESS: &str = "0xcA11bde05977b3631167028862bE2a173976CA11";

#[derive(Clone)]
struct ArbBot {
    address: Address,
    name: Arc<str>,
    tx_template: TxTemplate,
    last_bid_block: Arc<AtomicU64>,  // Lock-free cooldown tracking
}

// Pre-computed transaction template - avoids repeated calldata encoding in hot path
#[derive(Clone)]
struct TxTemplate {
    to: Address,
    calldata: alloy::primitives::Bytes,  // Pre-encoded execute() call
    chain_id: u64,
    gas_limit: u64,
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

// Background receipt polling request
struct ReceiptRequest {
    tx_hash: alloy::primitives::B256,
    bot_name: Arc<str>,
    block_detected: u64,
    expected_profit: String,
    check_time: String,
    exec_time: String,
    receive_time: Instant,
}

// In-flight request tracking
#[derive(Clone)]
struct PendingRequest {
    bots: Vec<ArbBot>,
    receive_time: Instant,
    block_num: u64,
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
        let header = "# Transaction Log (monadNewHeads + Single-Socket)\n\n| Timestamp | Bot | Tx Hash | Block Detected | Block Executed | Δ Blocks | Expected Profit | Check Time | Exec Time | Total Time |\n|-----------|-----|---------|----------------|----------------|----------|-----------------|------------|-----------|------------|\n";
        file.write_all(header.as_bytes()).expect("Failed to write header");
    }
    
    file.write_all(entry.as_bytes()).expect("Failed to write transaction log");
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenv::dotenv().ok();
    
    println!("╔════════════════════════════════════════════════════════════╗");
    println!("║   MONAD NEW HEADS BOT - Single-Socket Architecture        ║");
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
    
    // Detect provider from URL for display purposes
    let provider_name = if ws_url.contains("monad.xyz") || ws_url.contains("monad-rpc") { "Monad Native" }
        else if ws_url.contains("alchemy") { "Alchemy" }
        else if ws_url.contains("quiknode") || ws_url.contains("quicknode") { "QuickNode" }
        else if ws_url.contains("drpc") { "dRPC" }
        else if ws_url.contains("chainstack") { "Chainstack" }
        else if ws_url.contains("infura") { "Infura" }
        else if ws_url.contains("ankr") { "Ankr" }
        else { "Other" };
    
    println!("🔌 Single-Socket Mode: {}", provider_name);
    
    // Build bots from config
    let bots: Vec<ArbBot> = get_bot_addresses()
        .into_iter()
        .map(|(addr, name)| ArbBot {
            address: addr,
            name: Arc::from(name),
            tx_template: TxTemplate::new(addr),
            last_bid_block: Arc::new(AtomicU64::new(0)),
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
    use alloy::sol_types::SolCall;
    
    let signer = PrivateKeySigner::from_str(&private_key)?;
    let wallet_address = signer.address();
    let wallet = EthereumWallet::from(signer);
    
    // Pre-create broadcast providers at startup (for transaction broadcasts only)
    let mut broadcast_providers: Vec<Arc<dyn Provider + Send + Sync>> = vec![];
    
    for (env_var, name) in BROADCAST_ENDPOINTS {
        if let Ok(url) = std::env::var(env_var) {
            if let Ok(parsed) = Url::parse(&url) {
                let provider = ProviderBuilder::new().connect_http(parsed);
                broadcast_providers.push(Arc::new(provider));
                println!("📡 {} (broadcast only)", name);
            }
        }
    }
    println!("🔗 Broadcast providers: {}", broadcast_providers.len());
    
    let broadcast_providers = Arc::new(broadcast_providers);
    let wallet_arc = Arc::new(wallet.clone());
    
    // HTTP provider for initial nonce fetch and receipt polling only
    let rpc_url = std::env::var(PRIMARY_HTTPS_ENV)?;
    let http_provider = ProviderBuilder::new()
        .wallet(wallet.clone())
        .connect_http(Url::parse(&rpc_url)?);
    let http_provider = Arc::new(http_provider);
    
    // Get initial nonce
    let initial_nonce = http_provider.get_transaction_count(wallet_address).await?;
    let shared_nonce = Arc::new(AtomicU64::new(initial_nonce));
    
    println!("👛 Wallet: {:?}", wallet_address);
    println!("🔢 Initial nonce: {}", initial_nonce);
    
    // ========== BACKGROUND CHANNELS ==========
    // Non-blocking logging
    let (log_tx, mut log_rx) = mpsc::channel::<String>(500);
    tokio::spawn(async move {
        while let Some(msg) = log_rx.recv().await {
            println!("{}", msg);
        }
    });
    
    // Background receipt polling
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
    
    // ========== SINGLE-SOCKET WEBSOCKET WITH TCP_NODELAY ==========
    println!("\n🔌 Connecting Single-Socket WebSocket (TCP_NODELAY Enabled)...");
    
    let url = Url::parse(&ws_url)?;
    let host = url.host_str().ok_or(anyhow::anyhow!("Invalid host in WebSocket URL"))?;
    let port = url.port_or_known_default().unwrap_or(443);
    let use_tls = url.scheme() == "wss";
    
    // 1. Manually establish TCP connection
    let tcp_stream = TcpStream::connect((host, port)).await?;
    
    // 2. CRITICAL: Disable Nagle's Algorithm for immediate packet sending
    tcp_stream.set_nodelay(true)?;
    println!("⚡ TCP_NODELAY set to true");
    
    // 3. Upgrade to WebSocket (with TLS if wss://)
    // Use MaybeTlsStream to unify types between TLS and plain connections
    use tokio_tungstenite::MaybeTlsStream;
    
    let ws_stream = if use_tls {
        // Build native-tls connector
        let tls_connector = native_tls::TlsConnector::new()?;
        let tls_connector = TlsConnector::from(tls_connector);
        let tls_stream = tls_connector.connect(host, tcp_stream).await?;
        
        // Wrap in MaybeTlsStream for unified type
        let wrapped = MaybeTlsStream::NativeTls(tls_stream);
        
        // Upgrade to WebSocket (handshake only - TLS already done)
        let (ws, _) = client_async(url.as_str(), wrapped).await?;
        ws
    } else {
        // Plain ws:// (no TLS) - wrap for unified type
        let wrapped: MaybeTlsStream<TcpStream> = MaybeTlsStream::Plain(tcp_stream);
        
        // Just WebSocket handshake
        let (ws, _) = client_async(url.as_str(), wrapped).await?;
        ws
    };
    println!("✅ Single-Socket connected ({})", if use_tls { "TLS" } else { "Plain" });
    
    // Split into writer and reader
    let (ws_write, mut ws_read) = ws_stream.split();
    
    // Outbox channel for sending messages to the socket
    let (tx_outbox, mut rx_outbox) = mpsc::channel::<String>(1000);
    
    // Spawn writer task (takes ownership - no Mutex needed)
    let mut ws_write = ws_write;
    tokio::spawn(async move {
        while let Some(msg) = rx_outbox.recv().await {
            if let Err(e) = ws_write.send(Message::Text(msg)).await {
                println!("⚠️ WS Write Error: {:?}", e);
                break;
            }
        }
    });
    
    // Subscribe to monadNewHeads (using format! for speed)
    let subscribe_msg = r#"{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["monadNewHeads",{}]}"#;
    tx_outbox.send(subscribe_msg.to_string()).await?;
    println!("📤 Sent monadNewHeads subscription");
    
    // ========== PRE-ENCODE MULTICALL CALLDATA ==========
    // Build once, reuse for every block
    let keeper_profit_call = Arbitrage::keeperProfitCall {};
    let keeper_calldata = alloy::primitives::Bytes::from(keeper_profit_call.abi_encode());
    
    // Build Call3 array for all bots
    let calls: Vec<Multicall3::Call3> = bots.iter()
        .map(|bot| Multicall3::Call3 {
            target: bot.address,
            allowFailure: true,
            callData: keeper_calldata.clone(),
        })
        .collect();
    
    // Encode full multicall
    let multicall_instance = Multicall3::aggregate3Call { calls };
    let multicall_encoded = multicall_instance.abi_encode();
    let multicall_hex = format!("0x{}", hex::encode(&multicall_encoded));
    let multicall_target = MULTICALL3_ADDRESS;
    
    println!("📦 Pre-encoded multicall for {} bots ({} bytes)", bots.len(), multicall_encoded.len());
    
    if COOLDOWN_BLOCKS > 0 {
        println!("🧊 Cooldown: {} blocks (lock-free AtomicU64)", COOLDOWN_BLOCKS);
    }
    
    // Track in-flight requests (block_num -> request metadata)
    let pending_requests: Arc<tokio::sync::RwLock<FxHashMap<u64, PendingRequest>>> =
        Arc::new(tokio::sync::RwLock::new(FxHashMap::default()));
    
    // Track seen blocks
    let mut seen_blocks: FxHashSet<u64> = FxHashSet::default();
    let max_seen_history = 20;
    
    println!("\n🎯 Single-Socket Event Loop started (Safe SIMD Mode)...\n");
    
    // ========== THE EVENT LOOP ==========
    while let Some(msg_result) = ws_read.next().await {
        match msg_result {
            Ok(Message::Text(mut text)) => {
                // SIMD-JSON: Get mutable bytes for in-place parsing (2-3x faster)
                // SAFETY: WebSocket text messages are guaranteed valid UTF-8
                let bytes = unsafe { text.as_bytes_mut() };
                
                // ⚡ SINGLE-PASS PARSING ⚡
                // simd-json modifies buffer in-place, so we MUST parse exactly once
                let msg: CombinedMessage = match simd_json::from_slice(bytes) {
                    Ok(m) => m,
                    Err(_) => continue, // Skip invalid JSON
                };
                
                // --- PATH A: BLOCK NOTIFICATION ---
                // It's a notification if 'method' exists
                if let Some(method_str) = msg.method {
                    if method_str == "eth_subscription" {
                        if let Some(params) = msg.params {
                            let header = &params.result;
                            
                            // Only act on "Proposed" state (earliest)
                            if let Some(state) = header.commitState {
                                if state != "Proposed" {
                                    // Log other states for visibility
                                    let block_num = u64::from_str_radix(header.number.trim_start_matches("0x"), 16).unwrap_or(0);
                                    let _ = log_tx.try_send(format!("   {} Block #{}", 
                                        if state == "Voted" { "🗳️" } else { "✅" }, block_num));
                                    continue;
                                }
                            }
                            
                            let block_num = u64::from_str_radix(header.number.trim_start_matches("0x"), 16).unwrap_or(0);
                            if block_num == 0 { continue; }
                            
                            // Deduplicate
                            if seen_blocks.contains(&block_num) { continue; }
                            seen_blocks.insert(block_num);
                            if seen_blocks.len() > max_seen_history {
                                if let Some(&min_block) = seen_blocks.iter().min() {
                                    seen_blocks.remove(&min_block);
                                }
                            }
                            
                            let receive_time = Instant::now();
                            let block_timestamp = u64::from_str_radix(header.timestamp.trim_start_matches("0x"), 16).unwrap_or(0);
                            let now_unix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
                            let latency = now_unix.saturating_sub(block_timestamp);
                            
                            println!("\n══════════════════════════════════════════════════════════");
                            println!("🚀 PROPOSED Block #{} | Latency: {}s", block_num, latency);
                            
                            // Store pending request with ALL bots
                            {
                                let mut pending = pending_requests.write().await;
                                pending.insert(block_num, PendingRequest {
                                    bots: bots.clone(),
                                    receive_time,
                                    block_num,
                                });
                                pending.retain(|&k, _| k > block_num.saturating_sub(10));
                            }
                            
                            // Send eth_call via same WebSocket
                            let request = format!(
                                r#"{{"jsonrpc":"2.0","id":{},"method":"eth_call","params":[{{"to":"{}","data":"{}"}},"pending"]}}"#,
                                block_num, multicall_target, multicall_hex
                            );
                            
                            let _ = tx_outbox.try_send(request);
                        }
                    }
                    continue; // Done with notification
                }
                
                // --- PATH B: RPC RESPONSE ---
                // It's a response if 'id' exists and 'method' is missing
                if let Some(id) = msg.id {
                    if id <= 1 { continue; } // Skip subscription confirmation
                    
                    let block_id = id;
                    
                    // Check for errors
                    if let Some(error) = msg.error {
                        println!("⚠️ RPC Error for block {}: {:?}", block_id, error);
                        continue;
                    }
                    
                    let result_hex = match msg.result {
                        Some(r) => r,
                        None => continue,
                    };
                    
                    // Get pending request metadata
                    let pending_req = {
                        let pending = pending_requests.read().await;
                        pending.get(&block_id).cloned()
                    };
                    
                    let (all_bots, receive_time) = match pending_req {
                        Some(req) => (req.bots, req.receive_time),
                        None => continue,
                    };
                    
                    let check_elapsed = receive_time.elapsed();
                    println!("📦 Single-Socket Response ({} bots) in {:?}", all_bots.len(), check_elapsed);
                    
                    // Decode result
                    let result_bytes = match hex::decode(result_hex.trim_start_matches("0x")) {
                        Ok(b) => b,
                        Err(_) => continue,
                    };
                    
                    // Decode Multicall response
                    let multicall_returns = match Multicall3::aggregate3Call::abi_decode_returns(&result_bytes) {
                        Ok(r) => r,
                        Err(e) => {
                            println!("⚠️ Multicall decode error: {:?}", e);
                            continue;
                        }
                    };
                    
                    // Process each bot's result
                    for (i, result) in multicall_returns.iter().enumerate() {
                        if i >= all_bots.len() { break; }
                        if !result.success { continue; }
                        
                        // Decode keeperProfit return
                        let decoded = match Arbitrage::keeperProfitCall::abi_decode_returns(&result.returnData) {
                            Ok(d) => d,
                            Err(_) => continue,
                        };
                        
                        if !decoded.profitable { continue; }
                        
                        let bot = &all_bots[i];
                        let expected_profit = decoded.expectedProfit;
                        
                        // Check cooldown using lock-free AtomicU64
                        if COOLDOWN_BLOCKS > 0 {
                            let last = bot.last_bid_block.load(Ordering::Relaxed);
                            if block_id <= last + COOLDOWN_BLOCKS {
                                continue;
                            }
                        }
                        
                        // Mark cooldown immediately
                        if COOLDOWN_BLOCKS > 0 {
                            bot.last_bid_block.store(block_id, Ordering::Relaxed);
                        }
                        
                        // Spawn tx signing/broadcast
                        let bot_name = bot.name.clone();
                        let tx_template = bot.tx_template.clone();
                        let receive_time_clone = receive_time;
                        let block_num_clone = block_id;
                        let broadcast_providers_clone = broadcast_providers.clone();
                        let nonce_clone = shared_nonce.clone();
                        let wallet_clone = wallet_arc.clone();
                        let receipt_tx_clone = receipt_tx.clone();
                        let log_tx_clone = log_tx.clone();
                        let check_elapsed_clone = check_elapsed;
                        
                        tokio::spawn(async move {
                            let _ = log_tx_clone.try_send(format!(
                                "[{}] 🎯 PROFITABLE! Block {} Profit: {} (simd: {:?})", 
                                bot_name, block_num_clone, format_wei(expected_profit), check_elapsed_clone));
                            
                            let exec_start = Instant::now();
                            
                            use alloy::eips::eip2718::Encodable2718;
                            use alloy::network::TransactionBuilder;
                            
                            let current_nonce = nonce_clone.fetch_add(1, Ordering::SeqCst);
                            let profit_u128: u128 = expected_profit.try_into().unwrap_or(0);
                            let priority_fee = calculate_priority_fee(profit_u128);
                            let priority_gwei = priority_fee / 1_000_000_000;
                            
                            let tx_request = tx_template.build_with(current_nonce, priority_fee);
                            
                            let tx_envelope = match tx_request.build(&*wallet_clone).await {
                                Ok(e) => e,
                                Err(err) => {
                                    let _ = log_tx_clone.try_send(format!(
                                        "[{}] ⚠️ Failed to sign tx: {:?}", bot_name, err));
                                    return;
                                }
                            };
                            
                            let mut raw_tx_vec = Vec::with_capacity(512);
                            tx_envelope.encode_2718(&mut raw_tx_vec);
                            let raw_tx = alloy::primitives::Bytes::from(raw_tx_vec);
                            let tx_hash = *tx_envelope.tx_hash();
                            
                            let total_exec = exec_start.elapsed();
                            let _ = log_tx_clone.try_send(format!(
                                "[{}] ⚡ Signed tx nonce={} priority={}gwei (sign: {:?})", 
                                bot_name, current_nonce, priority_gwei, total_exec));
                            
                            // Parallel broadcasts
                            for provider in broadcast_providers_clone.iter() {
                                let p = provider.clone();
                                let tx = raw_tx.clone();
                                tokio::spawn(async move {
                                    let _ = p.send_raw_transaction(&tx).await;
                                });
                            }
                            
                            // Background receipt polling
                            let _ = receipt_tx_clone.try_send(ReceiptRequest {
                                tx_hash,
                                bot_name,
                                block_detected: block_num_clone,
                                expected_profit: format_wei(expected_profit),
                                check_time: format!("{:?}", check_elapsed_clone),
                                exec_time: format!("{:?}", total_exec),
                                receive_time: receive_time_clone,
                            });
                        });
                    }
                    
                    println!("⚡ Processed block {} via single-socket in {:?}", block_id, receive_time.elapsed());
                }
            }
            Ok(Message::Ping(_data)) => {
                // Pong is handled by the underlying tungstenite layer automatically
                // when using the higher-level API. If needed, we'd need to expand
                // the outbox to handle Message types, but for now this is fine.
            }
            Err(e) => {
                return Err(anyhow::anyhow!("WebSocket error: {:?}", e));
            }
            _ => {}
        }
    }
    
    Err(anyhow::anyhow!("WebSocket stream ended unexpectedly"))
}
