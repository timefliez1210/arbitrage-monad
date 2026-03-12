# Monad Arbitrage Bot

High-frequency arbitrage keeper for Monad blockchain. Exploits price discrepancies between Uniswap V4, PancakeSwap V3, and Kuru orderbooks.

## Architecture

Single-socket design: one WebSocket handles both `monadNewHeads` subscriptions and `eth_call` RPC requests, eliminating connection overhead.

```
┌─────────────────────┐     ┌──────────────────────────┐
│  Rust Keeper        │     │  Solidity Contracts      │
│  (arbitrage_monad)  │────▶│  ArbitrageAUSD.sol       │
└─────────────────────┘     │  ArbitrageUSDC.sol       │
         │                  │  ArbitragePancake*.sol   │
         ▼                  │  ArbitragePcsUni*.sol    │
   monadNewHeads            └──────────────────────────┘
   subscription                        │
                                        ▼
                            Uni V4 ◄──► Kuru OB
                            PCS V3 ◄──► Kuru OB
                            Uni V4 ◄──► PCS V3
```

## Features

- **monadNewHeads** — Acts on `Proposed` state blocks for earliest possible execution
- **Single-socket architecture** — Same WebSocket for subscriptions and RPC calls
- **Parallel broadcasts** — Transaction sent to multiple RPC endpoints simultaneously
- **Dynamic priority fees** — Scales with expected profit (configurable %)
- **Lock-free nonce tracking** — `AtomicU64` for contention-free nonce management
- **Background receipt polling** — Non-blocking confirmation tracking with Markdown logging

## Performance

| Metric | Value |
|--------|-------|
| Check Time | ~120–150ms |
| Δ+1 Rate | ~50% with monadNewHeads |
| Gas Limit | 4,000,000 |

## Contracts

| Contract | Pair | Strategy |
|----------|------|----------|
| `ArbitrageAUSD.sol` | MON/AUSD | Uniswap V4 ↔ Kuru |
| `ArbitrageUSDC.sol` | MON/USDC | Uniswap V4 ↔ Kuru |
| `ArbitragePancakeAUSD.sol` | AUSD/WMON | PancakeSwap V3 ↔ Kuru |
| `ArbitragePancakeUSDC.sol` | WMON/USDC | PancakeSwap V3 ↔ Kuru |
| `ArbitragePcsUniAUSD.sol` | AUSD/WMON | PancakeSwap V3 ↔ Uniswap V4 |
| `ArbitragePcsUniUSDC.sol` | WMON/USDC | PancakeSwap V3 ↔ Uniswap V4 |

Deployed addresses are not tracked in this repo.

## Setup

### Prerequisites

- Rust 1.70+
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Installation

```bash
git clone https://github.com/timefliez1210/arbitrage-monad.git
cd arbitrage-monad

# Install Foundry dependencies
forge install

# Build the keeper
cd arbitrage_monad
cargo build --release
```

### Configuration

Copy the example env file and fill in your endpoints:

```bash
cp arbitrage_monad/.env.example arbitrage_monad/.env
```

```env
PRIVATE_KEY=0x...

# WebSocket — monadNewHeads subscription + eth_call
CHAINSTACK_WS=wss://...
ALCHEMY_WEBSOCKET_API=wss://...
DRPC_WS=wss://...

# HTTPS — nonce fetch + parallel broadcast
CHAINSTACK_HTTP=https://...
QUICKNODE_HTTPS=https://...
INFURA_HTTPS_API=https://...
ALCHEMY_HTTPS_API=https://...
ANKR_HTTPS=https://...
DRPC_HTTPS=https://...
VALIDATION_CLOUD_HTTPS=https://...
```

Edit `arbitrage_monad/config.toml` to configure active bot addresses, primary endpoints, fee scaling, gas limit, and cooldown blocks — no recompilation needed.

### Running

```bash
cd arbitrage_monad
cargo run --release
```

## License

MIT
