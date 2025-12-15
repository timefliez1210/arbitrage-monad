# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 1: Build the Rust binary
# ═══════════════════════════════════════════════════════════════════════════════
FROM rust:1.83-slim-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifests first for better layer caching
COPY Cargo.toml Cargo.lock ./

# Create dummy main.rs to cache dependencies
RUN mkdir -p src && echo "fn main() {}" > src/main.rs

# Build dependencies only (this layer is cached)
RUN cargo build --release && rm -rf src target/release/arbitrage_monad*

# Copy actual source code
COPY src ./src

# Build the real application
RUN cargo build --release

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 2: Minimal runtime image
# ═══════════════════════════════════════════════════════════════════════════════
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies (SSL for HTTPS/WSS)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the binary from builder
COPY --from=builder /app/target/release/arbitrage_monad /app/arbitrage_monad

# Create a non-root user for security
RUN useradd -r -s /bin/false arbitrage && \
    chown -R arbitrage:arbitrage /app

USER arbitrage

# Run the bot
CMD ["./arbitrage_monad"]
