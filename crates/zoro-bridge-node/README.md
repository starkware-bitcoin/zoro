# Zoro Bridge Node

A Zcash block indexer that accumulates the Zcash blocks, and generates data required for running the [`assumevalid`](../../packages/assumevalid/) program.

## Overview

The Zoro Bridge Node serves as a data preprocessing layer for the Zcash ZK client, and as an API providing compressed SPV proofs. A compressed SPV proof is a self-sufficient transaction inclusion proof that does not require clients to store the Zcash headers locally nor keep connection to a Zcash RPC node.

## What it does

1. **Connects to Zcash Core** via RPC to fetch block headers
2. **Accumulates block headers** using Cairo-compatible Blake2 hashing
4. **Organizes output** into sharded JSON files for efficient access by the proving pipeline

Zoro bridge node does not handle reorgs, instead it operates with a configurable lag (by default — 1 block).

## Usage

### Command Line

```bash
# Basic usage with remote RPC node
cargo run --bin zoro-bridge-node -- --zcash-rpc-url https://zcash-mainnet.public.blastapi.io

# With authentication
cargo run --bin zoro-bridge-node -- --zcash-rpc-url http://localhost:8332 --zcash-rpc-userpwd user:password

# Custom data directory and shard size
cargo run --bin zoro-bridge-node -- \
  --zcash-rpc-url http://localhost:8332 \
  --db-path ./custom/app.db \
  --roots-dir ./custom/roots \
  --shard-size 5000

# Production setup with remote node and custom RPC server host
cargo run --bin zoro-bridge-node -- \
  --zcash-rpc-url https://zcash-node.example.com:8332 \
  --zcash-rpc-userpwd myuser:mypassword \
  --rpc-host 0.0.0.0:8080 \
  --shard-size 50000 \
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
| `--shard-size` | `10000` | - | Number of blocks per shard directory |
| `--log-level` | `info` | - | Logging verbosity |

> **Note**: When environment variables are set (either directly or via `.env` file), you can run the bridge node without any command line arguments. This is especially convenient for deployment and development setups.

## RPC Server and API Endpoints

The Zoro Bridge Node runs an HTTP RPC server that provides REST endpoints for querying block data and generating proofs. By default, the server binds to `127.0.0.1:5000`, but this can be configured using the `--rpc-host` option.

### Available Endpoints

#### GET /block-inclusion-proof/:height (needs update)

Generate an inclusion proof for a block at the specified height.

**Parameters:**
- `height` (path parameter): The block height to generate a proof for (0-indexed)
- `block_count` (query, optional): If provided, generate the proof against the header state at this total number of blocks

**Response:**
```json
{
  "peaks_hashes": [
    "0x5fd720d341e64d17d3b8624b17979b0d0dad4fc17d891796a3a51a99d3f41599",
    "0x693aa1ab81c6362fe339fc4c7f6d8ddb1e515701e58c5bb2fb54a193c8287fdc"
  ],
  "siblings_hashes": [
    "0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66"
  ],
  "leaf_count": 832500
}
```

**Response Fields:**
- `peaks_hashes`: Array of MMR peak hashes at the time of proof generation (hex-encoded strings)
- `siblings_hashes`: Array of sibling hashes needed to reconstruct the path to the root (hex-encoded strings)
- `leaf_count`: Total number of leaves (blocks) in the MMR the proof was generated against

**Status Codes:**
- `200 OK`: Proof generated successfully
- `500 Internal Server Error`: Failed to generate proof (e.g., invalid height)

#### GET /head

Get the current head (latest processed block height) from the MMR.

Note: The service operates with a lag of at least 1 block; `/head` returns the latest processed height (0-indexed), which is typically `block_count - 1`.

**Response:**
```json
832500
```

**Response:** The current head height as a JSON number (0-indexed)

**Status Codes:**
- `200 OK`: Block count retrieved successfully
- `500 Internal Server Error`: Failed to retrieve block count

### Usage Examples

```bash
# Get the current head (latest processed block height)
curl http://localhost:5000/head

# Generate a proof for block at height 100 (latest state)
curl "http://localhost:5000/block-inclusion-proof/100"

# Generate a proof for block at height 100 for an earlier state (block_count=90)
curl "http://localhost:5000/block-inclusion-proof/100?block_count=90"

# Get sparse roots for the latest state
curl "http://localhost:5000/roots"


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

## Requirements

- Access to a Zcash RPC node
- Sufficient disk space (numbers are for the first 900K blocks)
    * 300MB for the accumulator state DB
    * 3.6GB for the sparse roots files
