# Zoro Bridge Node

A Zcash block indexer + HTTP API server that:
- builds and persists Zcash **chain state** (used by `zoro-spv-verify`), and
- maintains the **FlyClient MMR accumulator** (ZIP-221 / `zcash_history`) for Heartwood+ blocks.

## Overview

The Zoro Bridge Node serves as a data layer for Zoro’s Zcash client stack:

- it **indexes** Zcash block headers from a Zcash Core RPC endpoint into a local SQLite database, and
- it exposes an **HTTP API** for retrieving headers, chain state, and generating proofs (FlyClient block inclusion proofs + transaction inclusion proofs).

## What it does

1. **Connects to Zcash Core** via RPC to fetch block headers and auxiliary data
2. **Stores headers + chain state** (difficulty target history, total work, timestamps, etc.) in SQLite
3. **Builds FlyClient MMRs** starting at Heartwood activation
   - The FlyClient MMR **resets per epoch** at Canopy and NU5 activation heights.

Zoro Bridge Node does not handle reorgs; instead it operates with a configurable lag (by default: **1 block**).

## Usage

### Command Line

```bash
# Basic usage with remote RPC node
cargo run --bin zoro-bridge-node -- --zcash-rpc-url https://zcash-mainnet.public.blastapi.io

# With authentication
cargo run --bin zoro-bridge-node -- --zcash-rpc-url http://localhost:8332 --zcash-rpc-userpwd user:password

# Custom data directory and server bind
cargo run --bin zoro-bridge-node -- \
  --zcash-rpc-url http://localhost:8332 \
  --db-path ./custom/app.db \
  --rpc-host 0.0.0.0:8080

# Production-ish setup: custom lag + quieter logs
cargo run --bin zoro-bridge-node -- \
  --zcash-rpc-url https://zcash-node.example.com:8332 \
  --zcash-rpc-userpwd myuser:mypassword \
  --block-lag 5 \
  --log-level warn
```

### Environment Variables

You can use environment variables instead of command line arguments:

```bash
# Set environment variables
export ZCASH_RPC="http://localhost:8332"
export USERPWD="user:password"

# Run with defaults (no arguments needed)
cargo run --bin zoro-bridge-node
```

### Using .env File

Create a `.env` file in the project directory:

```env
ZCASH_RPC=http://localhost:8332
USERPWD=user:password
```

Then simply run:

```bash
cargo run --bin zoro-bridge-node
```

## Configuration

| Option | Default | Environment Variable | Description |
|--------|---------|---------------------|-------------|
| `--zcash-rpc-url` | - | `ZCASH_RPC` | Zcash Core RPC URL (required) |
| `--zcash-rpc-userpwd` | - | `USERPWD` | RPC credentials in `user:password` format |
| `--rpc-host` | `127.0.0.1:5000` | - | Host and port for the bridge node's RPC server |
| `--db-path` | `./.data/app.db` | - | SQLite database path for app storage |
| `--id` | `blocks` | - | Logical namespace used for deterministic DB keys (useful if sharing a DB) |
| `--block-lag` | `1` | - | Indexing lag in blocks to reduce reorg risk |
| `--log-level` | `info` | - | Logging verbosity |

> **Note**: `RUST_LOG` is also supported (it overrides `--log-level`) because tracing uses `EnvFilter::try_from_default_env()`.

## RPC Server and API Endpoints

The Zoro Bridge Node runs an HTTP RPC server that provides REST endpoints for querying block data and generating proofs. By default, the server binds to `127.0.0.1:5000`, but this can be configured using the `--rpc-host` option.

### Available Endpoints

#### GET /block-inclusion-proof/:block_hash

Generate a FlyClient MMR inclusion proof for a block identified by its **block hash**.

**Parameters:**
- `block_hash` (path parameter): Block hash string as accepted by Zcash Core RPC
- `chain_height` (query, optional): If provided, generate the proof against an MMR state capped at this chain height (must be within the same epoch and >= the epoch start height).

**Response:**
```json
{
  "block_height": 903000,
  "peaks_hashes": [
    "0x5fd720d341e64d17d3b8624b17979b0d0dad4fc17d891796a3a51a99d3f41599",
    "0x693aa1ab81c6362fe339fc4c7f6d8ddb1e515701e58c5bb2fb54a193c8287fdc"
  ],
  "siblings_hashes": [
    "0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66"
  ],
  "leaf_index": 12345,
  "leaf_count": 14321
}
```

**Response Fields:**
- `block_height`: Block height resolved via Zcash RPC
- `peaks_hashes`: MMR peak hashes at the time of proof generation (hex strings)
- `siblings_hashes`: Sibling hashes needed to reconstruct the path to the root (hex strings)
- `leaf_index`: Leaf index **within the current epoch’s MMR**
- `leaf_count`: Total number of leaves in the epoch MMR at the proof’s state

**Status Codes:**
- `200 OK`: Proof generated successfully
- `400 Bad Request`: Block is before Heartwood activation height
- `404 Not Found`: Unknown block hash
- `500 Internal Server Error`: Proof generation failed

#### GET /head

Get the current head (**latest processed block height**) from the database.

**Response:**
```json
832500
```

**Response:** The current head height as a JSON number (0-indexed)

**Status Codes:**
- `200 OK`: Head retrieved successfully
- `500 Internal Server Error`: Failed to retrieve head

#### GET /headers?offset=&size=

Get a range of indexed Zcash block headers from the local database.

**Query:**
- `offset` (optional, default `0`): first height
- `size` (optional, default `10`): number of headers

#### GET /block-header/:block_height

Get a single block header (by height) from the local database.

#### GET /chain-state/:block_height

Get the computed chain state at `block_height` (used by `zoro-spv-verify`).

#### GET /transaction-proof/:tx_id

Get a transaction inclusion proof object (transaction + merkle proof + block header + block height).

### Usage Examples

```bash
# Get the current head (latest processed block height)
curl http://localhost:5000/head

# Get a range of headers
curl "http://localhost:5000/headers?offset=1000&size=10"

# Get a single header
curl "http://localhost:5000/block-header/1000"

# Generate a FlyClient MMR inclusion proof for a block hash (latest epoch state)
curl "http://localhost:5000/block-inclusion-proof/<HEARTWOOD_PLUS_BLOCK_HASH>"

# Generate a proof against a capped epoch state
curl "http://localhost:5000/block-inclusion-proof/<BLOCK_HASH>?chain_height=<EPOCH_CHAIN_HEIGHT>"

# Using a custom RPC host
cargo run --bin zoro-bridge-node -- \
  --zcash-rpc-url http://localhost:8332 \
  --rpc-host 0.0.0.0:8080

# Then query the custom endpoint
curl http://localhost:8080/head
```

### Integration

The RPC server is designed to be used by:
1. **ZK Clients**: To obtain inclusion proofs for Zcash blocks
2. **Monitoring Tools**: To track synchronization progress via the `/head` endpoint

## Utilities

### verify_flyclient

There is an auxiliary binary that can be used to sanity-check FlyClient roots against Zcash Core:

```bash
cargo run --bin verify_flyclient -- --zcash-rpc-url http://localhost:8332 --num-blocks 100
```

## Requirements

- Access to a Zcash RPC node
- Sufficient disk space for the SQLite DB at `--db-path` (it stores headers, chain states, and FlyClient MMR data)
