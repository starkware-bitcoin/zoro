//! Zcash FlyClient MMR Sync
//!
//! Syncs mainnet blocks into a SQLite-backed Merkle Mountain Range tree.
//! Supports resuming from previous runs - only fetches missing blocks.
//!
//! Usage:
//!   cargo run --bin sync                     # Sync to chain tip
//!   cargo run --bin sync -- --target 903100  # Sync to specific height
//!   cargo run --bin sync -- --db custom.db   # Use custom database file

use anyhow::{bail, Result};
use std::io::Write;
use turboboosted_flyclient::{
    activation_height, compute_root, node_data_from_header, NodeStore, SqliteStore,
};
use zcash_history::{Entry, EntryLink, Tree, V1};
use zcash_primitives::block::BlockHeader;

const RPC_URL: &str = "https://rpc.mainnet.ztarknet.cash";
const DEFAULT_DB: &str = "mmr.db";
const VERIFY_INTERVAL: u32 = 10; // Verify root against RPC every N blocks

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let db_path = get_arg(&args, "--db").unwrap_or(DEFAULT_DB);
    let target_arg: Option<u32> = get_arg(&args, "--target").and_then(|s| s.parse().ok());

    println!("Zcash FlyClient MMR Sync");
    println!("========================");
    println!("Database: {db_path}");
    println!("RPC: {RPC_URL}\n");

    let client = reqwest::Client::new();
    let start_height = activation_height::HEARTWOOD; // MMR starts at Heartwood activation

    // Determine target height
    let chain_tip = get_chain_height(&client).await?;
    let target = target_arg.unwrap_or(chain_tip);
    println!("Chain tip: {chain_tip}, Target: {target}");

    // Load existing state from SQLite
    let mut store = SqliteStore::open(db_path)?;
    let mut tree = load_tree(&store);
    let existing_leaves = tree.as_ref().map(|t| leaf_count(t.len())).unwrap_or(0);
    println!("Stored: {} nodes ({existing_leaves} leaves)", store.len());

    // Check if we're already synced
    let target_leaves = target - start_height;
    if existing_leaves >= target_leaves {
        println!("\n✓ Already synced!");
        print_tree_status(&tree, &store, &client, start_height).await?;
        return Ok(());
    }

    println!("\nSyncing {} blocks...\n", target_leaves - existing_leaves);

    // Main sync loop
    let mut last_progress = std::time::Instant::now();
    for leaf_idx in existing_leaves..target_leaves {
        let height = start_height + leaf_idx;

        // Fetch block data from RPC
        let (header, sapling_root, sapling_tx) = fetch_block(&client, height).await?;
        let node = node_data_from_header(&header, height, sapling_root, sapling_tx);

        // Append to tree and persist new nodes
        append_and_store(&mut tree, &mut store, node)?;

        // Verify root periodically
        let leaf_num = leaf_idx + 1;
        if leaf_num % VERIFY_INTERVAL == 0 {
            verify_and_print(&tree, &client, start_height + leaf_num).await?;
        }

        // Progress indicator
        if last_progress.elapsed().as_secs() >= 1 {
            let pct = leaf_num as f64 / target_leaves as f64 * 100.0;
            print!("\rHeight {height} ({pct:.1}%) - {} nodes", store.len());
            std::io::stdout().flush()?;
            last_progress = std::time::Instant::now();
        }
    }

    println!("\n\n✓ Sync complete!");
    print_tree_status(&tree, &store, &client, start_height).await
}

// ============ Tree Operations ============

/// Load tree from SQLite by replaying leaf nodes
fn load_tree(store: &SqliteStore) -> Option<Tree<V1>> {
    let mut tree: Option<Tree<V1>> = None;
    for pos in 0..store.len() {
        // Only process leaf positions (height 0 in MMR)
        if is_leaf_pos(pos) {
            if let Some(node) = store.get(pos) {
                match &mut tree {
                    None => tree = Some(Tree::new(1, vec![(0, Entry::new_leaf(node))], vec![])),
                    Some(t) => {
                        t.append_leaf(node).ok();
                    }
                }
            }
        }
    }
    tree
}

/// Append node to tree and persist all new nodes to store
fn append_and_store(
    tree: &mut Option<Tree<V1>>,
    store: &mut SqliteStore,
    node: zcash_history::NodeData,
) -> Result<()> {
    match tree {
        None => {
            *tree = Some(Tree::new(
                1,
                vec![(0, Entry::new_leaf(node.clone()))],
                vec![],
            ));
            store.set(0, node);
        }
        Some(t) => {
            // append_leaf returns all newly created node positions
            let new_positions = t.append_leaf(node).map_err(|e| anyhow::anyhow!("{e:?}"))?;
            for link in new_positions {
                if let EntryLink::Stored(pos) = link {
                    if let Ok(entry) = t.resolve_link(link) {
                        store.set(pos, entry.data().clone());
                    }
                }
            }
        }
    }
    Ok(())
}

/// Verify tree root against RPC and print result
async fn verify_and_print(
    tree: &Option<Tree<V1>>,
    client: &reqwest::Client,
    height: u32,
) -> Result<()> {
    let tree = tree.as_ref().unwrap();
    let our_root = root_hex(tree);
    let expected = fetch_block_commitment(client, height).await?;
    let ok = our_root == expected;
    println!("Block {height}: root {}", if ok { "✓" } else { "✗" });
    if !ok {
        bail!("Root mismatch at {height}! Expected {expected}, got {our_root}");
    }
    Ok(())
}

/// Print final tree status
async fn print_tree_status(
    tree: &Option<Tree<V1>>,
    store: &SqliteStore,
    client: &reqwest::Client,
    start_height: u32,
) -> Result<()> {
    let Some(tree) = tree else { return Ok(()) };

    let leaves = leaf_count(tree.len());
    let root = root_hex(tree);
    let height = start_height + leaves;
    let expected = fetch_block_commitment(client, height).await?;

    println!("\nTree: {} nodes, {leaves} leaves", tree.len());
    println!("Stored: {} nodes", store.len());
    println!("Root: {root}");
    println!(
        "Matches block {height}: {}",
        if root == expected { "✓" } else { "✗" }
    );
    Ok(())
}

// ============ MMR Helpers ============

/// Compute root hash as little-endian hex string
fn root_hex(tree: &Tree<V1>) -> String {
    let mut root = compute_root(tree).unwrap();
    root.reverse(); // Zcash uses little-endian for display
    hex::encode(root)
}

/// Count leaf nodes in an MMR of given size
fn leaf_count(tree_size: u32) -> u32 {
    (0..tree_size).filter(|&p| is_leaf_pos(p)).count() as u32
}

/// Check if MMR position is a leaf (height 0)
fn is_leaf_pos(pos: u32) -> bool {
    pos_height(pos) == 0
}

/// Compute height of node at given MMR position
fn pos_height(mut pos: u32) -> u32 {
    // MMR positions: leaves at height 0, parents at higher levels
    // Position pattern: 0,1,2,3,4,5,6,7,8,9,10...
    // Heights:         0,0,1,0,0,1,2,0,0,1,0...
    loop {
        let n = pos + 1;
        if (n & (n + 1)) == 0 {
            return n.count_ones() - 1;
        }
        let left_subtree = (1u32 << (32 - n.leading_zeros() - 1)) - 1;
        pos -= left_subtree;
    }
}

// ============ RPC Helpers ============

/// JSON-RPC call to Zcash node
async fn rpc(
    client: &reqwest::Client,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let body = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    let resp: serde_json::Value = client
        .post(RPC_URL)
        .json(&body)
        .send()
        .await?
        .json()
        .await?;
    Ok(resp["result"].clone())
}

async fn get_chain_height(client: &reqwest::Client) -> Result<u32> {
    Ok(
        rpc(client, "getblockchaininfo", serde_json::json!([])).await?["blocks"]
            .as_u64()
            .unwrap() as u32,
    )
}

/// Fetch block header, sapling root, and shielded tx count
async fn fetch_block(
    client: &reqwest::Client,
    height: u32,
) -> Result<(BlockHeader, [u8; 32], u64)> {
    let hash = rpc(client, "getblockhash", serde_json::json!([height]))
        .await?
        .as_str()
        .unwrap()
        .to_string();

    // Get raw header
    let hdr_hex = rpc(client, "getblockheader", serde_json::json!([&hash, false]))
        .await?
        .as_str()
        .unwrap()
        .to_string();
    let header = BlockHeader::read(&mut hex::decode(&hdr_hex)?.as_slice())
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;

    // Get block details for sapling root and tx count
    let blk = rpc(client, "getblock", serde_json::json!([&hash, 2])).await?;

    let mut sapling_root = [0u8; 32];
    sapling_root.copy_from_slice(&hex::decode(blk["finalsaplingroot"].as_str().unwrap())?);
    sapling_root.reverse();

    // Count transactions with shielded components
    let sapling_tx = blk["tx"]
        .as_array()
        .map(|txs| {
            txs.iter()
                .filter(|t| {
                    !t["vShieldedSpend"]
                        .as_array()
                        .map(|a| a.is_empty())
                        .unwrap_or(true)
                        || !t["vShieldedOutput"]
                            .as_array()
                            .map(|a| a.is_empty())
                            .unwrap_or(true)
                })
                .count() as u64
        })
        .unwrap_or(0);

    Ok((header, sapling_root, sapling_tx))
}

/// Fetch blockcommitments field (the MMR root) for a given height
async fn fetch_block_commitment(client: &reqwest::Client, height: u32) -> Result<String> {
    let hash = rpc(client, "getblockhash", serde_json::json!([height]))
        .await?
        .as_str()
        .unwrap()
        .to_string();
    let blk = rpc(client, "getblock", serde_json::json!([&hash, 1])).await?;
    Ok(blk["blockcommitments"].as_str().unwrap().to_string())
}

// ============ CLI Helpers ============

fn get_arg<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
}
