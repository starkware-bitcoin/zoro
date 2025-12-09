//! Quick verification that our FlyClient root matches mainnet
//!
//! Usage: cargo run --bin verify_flyclient -- --zcash-rpc-url <URL>

use std::sync::Arc;

use accumulators::{
    hasher::flyclient::{decode_node_data, encode_node_data, ZcashFlyclientHasher},
    mmr::{helpers::find_peaks, MMR},
    store::{memory::InMemoryStore, SubKey},
};
use clap::{command, Parser};
use primitive_types::U256;
use zcash_history::{NodeData, Version, V1};
use zoro_zcash_client::ZcashClient;

const HEARTWOOD_ACTIVATION: u32 = 903_000;

/// Compute root directly using zcash_history for debugging
async fn compute_zcash_root_directly(mmr: &MMR) -> String {
    let elements_count = mmr.elements_count.get().await.unwrap_or(0);
    if elements_count == 0 {
        return "empty".to_string();
    }

    let peaks_idxs = find_peaks(elements_count);

    // Retrieve all peak NodeData values
    let mut peaks: Vec<NodeData> = Vec::new();
    for idx in &peaks_idxs {
        let key = format!("{}:hashes:{}", mmr.mmr_id, idx);
        if let Ok(Some(val)) = mmr.store.get(&key).await {
            if let Ok(node) = decode_node_data(&val) {
                peaks.push(node);
            }
        }
    }

    if peaks.is_empty() {
        return "no_peaks".to_string();
    }

    // Bag the peaks LEFT to RIGHT using V1::combine (as per zcash_history/ZIP-221)
    // For peaks [A, B, C]: combine(combine(A, B), C) = ((A, B), C)
    let mut iter = peaks.into_iter();
    let mut bagged = iter.next().unwrap();
    for peak in iter {
        bagged = V1::combine(&bagged, &peak);
    }

    // Return the hash of the bagged root
    let mut hash = V1::hash(&bagged);
    hash.reverse(); // big-endian for display
    hex::encode(hash)
}

mod branch_id {
    pub const HEARTWOOD: u32 = 0xf5b9230b;
    pub const CANOPY: u32 = 0xe9ff75a6;
    pub const NU5: u32 = 0xc2d6d0b4;
}

fn branch_id_for_height(height: u32) -> u32 {
    if height >= 1_687_104 {
        branch_id::NU5
    } else if height >= 1_046_400 {
        branch_id::CANOPY
    } else {
        branch_id::HEARTWOOD
    }
}

fn work_from_bits(bits: u32) -> U256 {
    let exp = (bits >> 24) as usize;
    let mantissa = bits & 0x007fffff;
    if exp == 0 {
        return U256::zero();
    }
    let target = if exp <= 3 {
        U256::from(mantissa >> (8 * (3 - exp)))
    } else {
        U256::from(mantissa) << (8 * (exp - 3))
    };
    if target.is_zero() {
        return U256::zero();
    }
    (U256::MAX - target) / (target + 1) + 1
}

fn node_data_from_parts(
    block_hash: [u8; 32],
    height: u32,
    timestamp: u32,
    bits: u32,
    sapling_root: [u8; 32],
    sapling_tx: u64,
) -> NodeData {
    let branch_id = branch_id_for_height(height);
    let work = work_from_bits(bits);
    let mut wb = [0u8; 32];
    work.to_little_endian(&mut wb);
    NodeData {
        consensus_branch_id: branch_id,
        subtree_commitment: block_hash,
        start_time: timestamp,
        end_time: timestamp,
        start_target: bits,
        end_target: bits,
        start_sapling_root: sapling_root,
        end_sapling_root: sapling_root,
        subtree_total_work: U256::from_little_endian(&wb),
        start_height: height as u64,
        end_height: height as u64,
        sapling_tx,
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// Zcash RPC URL
    #[arg(long, env = "ZCASH_RPC")]
    zcash_rpc_url: String,
    /// Zcash RPC user:password (optional)
    #[arg(long, env = "USERPWD")]
    zcash_rpc_userpwd: Option<String>,
    /// Number of blocks to verify
    #[arg(long, default_value = "100")]
    num_blocks: u32,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    println!("FlyClient Root Verification");
    println!("===========================");
    println!(
        "Starting from Heartwood activation height: {}",
        HEARTWOOD_ACTIVATION
    );
    println!("Verifying {} blocks\n", cli.num_blocks);

    let client = ZcashClient::new(cli.zcash_rpc_url, cli.zcash_rpc_userpwd).await?;

    let store = Arc::new(InMemoryStore::new(Some("flyclient_verify")));
    let hasher = Arc::new(ZcashFlyclientHasher);
    let mut mmr = MMR::new(store.clone(), hasher, Some("verify".to_string()));

    let mut verified = 0;
    let mut errors = 0;

    for i in 0..cli.num_blocks {
        let height = HEARTWOOD_ACTIVATION + i;

        // Fetch block data
        let (header, hash) = client.get_block_header_by_height(height).await?;
        let (sapling_root, sapling_tx) = client.get_block_flyclient_data(height).await?;

        // Create NodeData
        let bits = u32::from_be_bytes(header.difficulty_threshold.bytes_in_display_order());
        let node = node_data_from_parts(
            hash.0,
            height,
            header.time.timestamp() as u32,
            bits,
            sapling_root,
            sapling_tx,
        );

        // Append to MMR
        mmr.append(encode_node_data(&node)).await?;

        // Get our computed root
        let our_root = mmr.root_hash.get(SubKey::None).await?.unwrap_or_default();

        // Get expected root from next block's blockcommitments
        let verify_height = height + 1;
        let expected = client.get_block_commitment(verify_height).await?;

        if our_root == expected {
            verified += 1;
            if i < 10 || i % 10 == 0 {
                println!("✓ Height {} (leaf {}) - Root matches", height, i + 1);
            }
        } else {
            errors += 1;
            println!("✗ Height {} (leaf {}) - ROOT MISMATCH!", height, i + 1);
            println!("  Our root:      {}", our_root);
            println!("  Expected:      {}", expected);

            // Debug: compute root using zcash_history directly
            let debug_root = compute_zcash_root_directly(&mmr).await;
            println!("  Direct zcash:  {}", debug_root);

            if errors >= 3 {
                println!("\nToo many errors, stopping.");
                break;
            }
        }
    }

    println!("\n===========================");
    println!("Results: {} verified, {} errors", verified, errors);

    if errors == 0 {
        println!("SUCCESS: All FlyClient roots match mainnet!");
    } else {
        println!("FAILURE: Some roots did not match.");
    }

    Ok(())
}
