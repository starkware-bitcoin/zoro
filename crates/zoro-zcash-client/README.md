# Zoro Zcash Client

A robust Zcash RPC client library for Rust that handles communication with Zcash nodes, offering retry logic, Merkle proof verification, and type-safe serialization.

## Overview

The Zoro Zcash Client serves as a foundational interface for Rust applications interacting with the Zcash network. It wraps the standard JSON-RPC interface with strong typing (via `zebra-chain`), automatic retries for transient failures, and utilities for cryptographic verification.

## What it does

1.  **Robust RPC Communication**: Connects to Zcash Core nodes with built-in exponential backoff retry logic for reliable data fetching.
2.  **Type-Safe Access**: Provides strictly typed access to blocks, headers, and transactions using `zebra-chain` structures.
3.  **Merkle Proofs**: Capabilities to build block Merkle trees and generate/verify transaction inclusion proofs.
4.  **Chain Synchronization**: Utilities to wait for blocks and track chain height with configurable lag.
5.  **Serialization Helpers**: Efficient hex and byte serialization for Zcash primitives compatible with `serde`.

## Usage

### Basic Client Setup

```rust
use zoro_zcash_client::ZcashClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize client with URL and optional credentials
    let client = ZcashClient::new(
        "http://127.0.0.1:8232".to_string(),
        Some("user:password".to_string())
    ).await?;

    // Get current chain height
    let height = client.get_chain_height().await?;
    println!("Current height: {}", height);

    Ok(())
}
```

### Fetching Data

```rust
// Get block hash by height
let hash = client.get_block_hash(100_000).await?;

// Get block header
let header = client.get_block_header(&hash).await?;

// Get full transaction
let tx = client.get_transaction(&tx_hash).await?;
```

### Merkle Proof Verification

```rust
// Build Merkle tree for a block to generate proofs
let tree = client.build_block_merkle_tree(block_height).await?;

// Generate proof for transaction at index 0
let proof = tree.generate_proof(0)?;

// Verify the proof locally
let is_valid = proof.verify(tx_hash.into());
assert!(is_valid);
```

## Configuration

The client is configured programmatically at initialization:

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | `String` | The Zcash RPC endpoint URL |
| `userpwd` | `Option<String>` | Optional "username:password" for Basic Auth |

## Requirements

*   Access to a Zcash node (e.g., `zcashd` or `zebrad`) with RPC enabled.
