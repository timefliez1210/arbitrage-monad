# Monad Arbitrage Bot

High-frequency arbitrage bot for Monad blockchain, exploiting price discrepancies between Uniswap V4 and Kuru orderbook.

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐
│  Rust Keeper        │     │  Solidity Contracts  │
│  (arbitrage_monad)  │────▶│  ArbitrageAUSD.sol   │
│                     │     │  ArbitrageUSDC.sol   │
└─────────────────────┘     └──────────────────────┘
         │                           │
         ▼                           ▼
   monadNewHeads              Uniswap V4 ◄──► Kuru OB
   subscription                 (MON/AUSD)
```

## Features

- **monadNewHeads support** - Early block notifications for faster execution
- **Dynamic priority fees** - Fee scales with profit (2% of profit → priority)
- **Parallel broadcasts** - Sends to 6 RPC endpoints simultaneously
- **Connection pooling** - Pre-warmed HTTP clients for minimal latency
- **Atomic nonce tracking** - Lock-free nonce management
- **Background receipt polling** - Non-blocking tx confirmation

## Performance

| Metric | Value |
|--------|-------|
| Check Time | ~35-50ms (QuickNode) |
| Δ+1 Rate | 84% with monadNewHeads |
| Gas Limit | 3,000,000 |

## Setup

### Prerequisites

- Rust 1.70+
- Foundry (forge, cast)

### Installation

```bash
# Clone
git clone https://github.com/timefliez1210/arbitrage-monad.git
cd arbitrage-monad

# Install Foundry deps
forge install

# Build Rust keeper
cd arbitrage_monad
cargo build --release
```

### Configuration

Create `.env` in project root:

```env
PRIVATE_KEY=0x...

# WebSocket (monadNewHeads)
QUICKNODE_WS=wss://...
CHAINSTACK_WS=wss://...

# HTTPS (RPC calls)
QUICKNODE_HTTPS=https://...
CHAINSTACK_HTTP=https://...
ANKR_HTTPS=https://...
```

Edit `arbitrage_monad/src/config.rs` to set primary endpoints:

```rust
pub const PRIMARY_WS_ENV: &str = "QUICKNODE_WS";
pub const PRIMARY_HTTPS_ENV: &str = "QUICKNODE_HTTPS";
```

### Running

```bash
cd arbitrage_monad
cargo run --release
```

## Contracts

| Contract | Description |
|----------|-------------|
| `ArbitrageAUSD.sol` | MON/AUSD arbitrage (Uniswap V4 ↔ Kuru) |
| `ArbitrageUSDC.sol` | MON/USDC arbitrage (Uniswap V4 ↔ Kuru) |

### Deployment

```bash
forge script script/DeployArbitrageAUSD.s.sol --rpc-url $RPC --broadcast
```

## License

MIT