# Keeper — Design Notes

This document explains the key architectural decisions in the keeper and why they matter for latency.

---

## Design Decisions

### Single-Socket Architecture

The same WebSocket connection is used for both block subscriptions (`monadNewHeads`) and `eth_call` RPC requests.

Most keeper implementations open a separate HTTP or WebSocket connection for the profitability check after receiving a block notification. This means:
- TCP handshake or connection acquisition from pool
- TLS negotiation (on `wss://`)
- A separate round-trip on a potentially different server

With a single socket, the `eth_call` is sent on an already-warm, already-authenticated connection the moment a block notification arrives. The server processes both on the same session, eliminating the reconnection overhead.

The trade-off is that a single socket is a single point of failure. The reconnection loop in `main()` handles this — on any error the bot re-establishes the socket and re-fetches the nonce from chain.

---

### TCP_NODELAY

Nagle's algorithm batches small TCP packets to reduce network congestion. For a keeper sending sub-1KB JSON payloads, this introduces up to 40ms of artificial delay waiting for the buffer to fill.

`TCP_NODELAY` is set on the raw TCP stream before the WebSocket handshake, ensuring every outgoing message is sent as its own packet immediately.

```rust
tcp_stream.set_nodelay(true)?;
```

This must be set on the raw `TcpStream` before it is wrapped in TLS and then WebSocket layers — the option is not accessible through the higher-level WebSocket API.

---

### SIMD-JSON

Standard `serde_json` uses scalar byte-by-byte parsing. `simd-json` uses SIMD CPU instructions to parse JSON 2–3x faster by processing multiple bytes per clock cycle.

The catch: `simd-json` modifies the input buffer in-place during parsing (replacing quote characters with null bytes for zero-copy string slices). This requires a `&mut [u8]` rather than a `&[u8]`, which means an `unsafe` cast from the WebSocket `String`:

```rust
// SAFETY: WebSocket text messages are guaranteed valid UTF-8 by the spec.
// simd-json modifies the buffer in-place but only within valid UTF-8 boundaries.
let bytes = unsafe { text.as_bytes_mut() };
```

The buffer is used exactly once per message and dropped immediately after. The safety invariant holds because `tokio-tungstenite` only produces `Message::Text` for valid UTF-8.

The `CombinedMessage` struct is designed for single-pass parsing — both notification fields (`method`, `params`) and response fields (`id`, `result`, `error`) are parsed in one call, avoiding a second parse to determine the message type.

---

### Pre-Encoded Calldata

Two pieces of calldata are computed once at startup and reused for every block:

**Multicall hex** — the `aggregate3` call encoding all `keeperProfit()` calls for every configured bot. This is a fixed byte string that never changes between blocks. Building it once saves repeated ABI encoding in the hot path.

**`TxTemplate`** — each bot pre-computes the `execute()` calldata. At execution time, only the gas parameters and nonce need to be set via `build_with()`, which is a cheap struct construction rather than a full ABI encode.

---

### Lock-Free Nonce Tracking

Nonce management uses an `AtomicU64` shared across all spawned transaction tasks:

```rust
let current_nonce = nonce_clone.fetch_add(1, Ordering::SeqCst);
```

`fetch_add` with `SeqCst` is atomic — two tasks racing to sign transactions will each get a unique nonce without a mutex. A `Mutex<u64>` would work but introduces contention and potential priority inversion in an async context.

The nonce is re-fetched from chain on every reconnection, recovering from any gaps that occur during disconnection or failed signing.

---

### Channel-Based WebSocket Writer

The WebSocket write half is owned by a dedicated `tokio::spawn` task that reads from an `mpsc` channel. All other code sends strings to the channel via `try_send`.

The alternative — wrapping the write half in `Arc<Mutex<...>>` — introduces lock contention and async blocking. `try_send` on an unbounded-ish channel (capacity 1000) is a non-blocking push that never suspends the caller.

---

### Parallel Broadcast

On a profitable block, the signed raw transaction is sent via two paths concurrently:

1. **Hot WebSocket** — pushed to the outbox channel, sent on the already-open socket within ~0.1ms.
2. **HTTP scattergun** — `tokio::spawn` fires the transaction to every configured HTTP endpoint simultaneously. Each provider call is fully independent.

No provider is awaited. The WebSocket path has the lowest latency; the HTTP endpoints serve as redundant fallbacks in case any single RPC node is slow to propagate.

---

### monadNewHeads + Proposed State

Monad emits block notifications at multiple consensus states: `Proposed`, `Voted`, and `Finalized`. The keeper acts only on `Proposed` — the earliest possible signal that a block exists, before it has been voted on by the validator set.

Acting on `Proposed` maximises the window to get a transaction into the next block. The trade-off is that `Proposed` blocks are occasionally not finalised (in practice this is rare on Monad). Transactions that land in a non-finalised block are simply not included and the nonce is reused.

---

### jemalloc

The default system allocator (`ptmalloc` on Linux) has higher fragmentation and slower allocation for the access patterns of async Rust (many small, short-lived allocations from futures and JSON buffers). `jemalloc` reduces allocator overhead in hot paths.

```rust
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;
```

---

### OnceLock Config

`config.toml` is read once at startup and stored in a `OnceLock<Config>`. Every subsequent call to `config::config()` is a pointer dereference with no locking. This makes the config accessible from spawned tasks without passing it through every function signature.

---

### FxHashMap / FxHashSet

`rustc_hash::FxHashMap` uses a non-cryptographic hash function (FxHash) that is significantly faster than the default `SipHash` used by `std::HashMap`. The seen-blocks deduplication set is written and read on every block — the hash cost matters here.

---

## Known Issues

**Nonce gap on signing failure**
`fetch_add` increments the nonce before `tx_request.build()` is called. If signing fails (e.g. wallet error), the nonce is consumed but no transaction is sent. Subsequent transactions use the next nonce, leaving a gap that stalls inclusion until the gap is filled. The reconnection loop re-fetches the nonce from chain and recovers, but mid-session this can cause missed blocks.

**`log_transaction` panics on file error**
The transaction log writer uses `.expect()`. If the log file cannot be opened (disk full, bad path in `config.toml`), the background receipt task panics silently. The bot continues running but stops recording transactions.

**Unconditional timing instrumentation**
Variables like `rwlock_elapsed`, `hex_decode_elapsed`, and `response_parse_time` are computed on every block regardless of whether `DEBUG_TIMING` is enabled. The overhead is negligible (a few `Instant::now()` calls) but they add noise to the code.

**Block deduplication uses linear scan for eviction**
`seen_blocks.iter().min()` iterates the full set (capped at 20 entries) to find the oldest block to evict. A `VecDeque` with a fixed capacity would be O(1) for both insertion and eviction, though the current approach is fast enough in practice.
