//! Zcash FlyClient MMR Sync & Proof Generator
//!
//! Syncs mainnet blocks into a SQLite-backed Merkle Mountain Range tree.
//! Can generate and verify inclusion proofs for any synced block.
//!
//! Usage:
//!   cargo run --bin sync                              # Sync to chain tip
//!   cargo run --bin sync -- --from 903000 --target 903100  # Sync specific range
//!   cargo run --bin sync -- --target 903100           # Sync to specific height
//!   cargo run --bin sync -- --db custom.db            # Use custom database file
//!   cargo run --bin sync -- --proof <BLOCK_HASH>      # Generate proof for block
//!   cargo run --bin sync -- --verify <PROOF_FILE>     # Verify proof from JSON file

use anyhow::{bail, Result};
use std::io::Write;
use turboboosted_flyclient::{
    activation_height, compute_root, generate_proof, node_data_from_header, NodeStore, SqliteStore,
    ZcashInclusionProof,
};
use zcash_history::{Entry, EntryLink, Tree, V1};
use zcash_primitives::block::BlockHeader;

const RPC_URL: &str = "https://rpc.mainnet.ztarknet.cash";
const DEFAULT_DB: &str = "mmr.db";
const VERIFY_INTERVAL: u32 = 10;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let db_path = get_arg(&args, "--db").unwrap_or(DEFAULT_DB);

    // Generate a proof
    if let Some(block_hash) = get_arg(&args, "--proof") {
        return generate_block_proof(db_path, block_hash).await;
    }

    // Verify a proof
    if let Some(proof_file) = get_arg(&args, "--verify") {
        return verify_proof(db_path, proof_file).await;
    }

    // Otherwise, run sync
    run_sync(&args, db_path).await
}

// ============ Proof Generation ============

/// Generate and print a Merkle inclusion proof for a block
async fn generate_block_proof(db_path: &str, block_hash: &str) -> Result<()> {
    let client = reqwest::Client::new();
    let start_height = activation_height::HEARTWOOD;

    // Load tree from SQLite
    let store = SqliteStore::open(db_path).await?;
    let tree = load_tree(&store).ok_or_else(|| anyhow::anyhow!("No tree data in database"))?;
    let leaves = leaf_count(tree.len());

    println!("Generating proof for block {block_hash}");
    println!("Tree has {leaves} blocks\n");

    // Look up block height from hash
    let height = fetch_block_height(&client, block_hash).await?;
    println!("Block height: {height}");

    // Validate block is in our tree
    if height < start_height {
        bail!("Block {height} is before Heartwood activation ({start_height})");
    }
    let leaf_index = height - start_height;
    if leaf_index >= leaves {
        bail!(
            "Block {height} not synced yet. Tree only has blocks up to {}",
            start_height + leaves - 1
        );
    }

    // Generate proof
    let proof = generate_proof(&tree, leaf_index, leaves)
        .map_err(|e| anyhow::anyhow!("Failed to generate proof: {e}"))?;

    // Compute root for verification info
    let root = root_hex(&tree);

    println!("Leaf index: {leaf_index}");
    println!("Siblings: {}", proof.siblings.len());
    println!("Peaks: {}", proof.peaks.len());
    println!("Tree root: {root}\n");

    // Output proof as JSON
    let json = proof.to_json()?;
    println!("Proof JSON:\n{json}");

    // Verify it works
    let mut root_bytes = compute_root(&tree).unwrap();
    root_bytes.reverse();
    let mut root_be = root_bytes;
    root_be.reverse();
    if proof.verify(&root_be) {
        println!("\n✓ Proof verified successfully");
    } else {
        println!("\n✗ Proof verification failed!");
    }

    Ok(())
}

/// Get block height from block hash via RPC
async fn fetch_block_height(client: &reqwest::Client, hash: &str) -> Result<u32> {
    let blk = rpc(client, "getblock", serde_json::json!([hash, 1])).await?;
    blk["height"]
        .as_u64()
        .map(|h| h as u32)
        .ok_or_else(|| anyhow::anyhow!("Block not found: {hash}"))
}

// ============ Proof Verification ============

/// Verify a proof from a JSON file against the current tree root
async fn verify_proof(db_path: &str, proof_path: &str) -> Result<()> {
    let client = reqwest::Client::new();
    let mmr_start = activation_height::HEARTWOOD;

    // Load proof from file
    let json = std::fs::read_to_string(proof_path)
        .map_err(|e| anyhow::anyhow!("Failed to read proof file: {e}"))?;

    let proof = ZcashInclusionProof::from_json(&json)
        .map_err(|e| anyhow::anyhow!("Failed to parse proof: {e}"))?;

    // Extract block info from proof
    let block_height = proof.block_height() as u32;
    let block_hash = hex::encode(proof.leaf.subtree_commitment);

    println!("Verifying proof for block {block_height}");
    println!("Block hash: {block_hash}");
    println!(
        "Siblings: {}, Peaks: {}\n",
        proof.siblings.len(),
        proof.peaks.len()
    );

    // Load tree from SQLite
    let store = SqliteStore::open(db_path).await?;
    let tree = load_tree(&store).ok_or_else(|| anyhow::anyhow!("No tree data in database"))?;
    let leaves = leaf_count(tree.len());
    let tree_height = mmr_start + leaves;

    println!(
        "Tree has {leaves} blocks (up to height {})",
        tree_height - 1
    );

    // Get tree root
    let root = compute_root(&tree).ok_or_else(|| anyhow::anyhow!("Failed to compute root"))?;
    let root_hex = {
        let mut r = root;
        r.reverse();
        hex::encode(r)
    };
    println!("Tree root: {root_hex}\n");

    // Verify proof
    if proof.verify(&root) {
        println!("✓ Proof is VALID");
        println!("  Block {block_height} is included in the tree");

        // Also verify against RPC if block is in range
        if block_height < tree_height {
            let expected_root = fetch_block_commitment(&client, tree_height).await?;
            if root_hex == expected_root {
                println!("  Tree root matches mainnet at height {tree_height}");
            }
        }

        Ok(())
    } else {
        println!("✗ Proof is INVALID");
        println!("  Block may not be in the tree, or proof is corrupted");
        bail!("Proof verification failed")
    }
}

// ============ Sync ============

async fn run_sync(args: &[String], db_path: &str) -> Result<()> {
    let from_arg: Option<u32> = get_arg(args, "--from").and_then(|s| s.parse().ok());
    let target_arg: Option<u32> = get_arg(args, "--target").and_then(|s| s.parse().ok());

    println!("Zcash FlyClient MMR Sync");
    println!("========================");
    println!("Database: {db_path}");
    println!("RPC: {RPC_URL}\n");

    let client = reqwest::Client::new();
    let mmr_start = activation_height::HEARTWOOD;

    // Determine sync range
    let chain_tip = get_chain_height(&client).await?;
    let from_height = from_arg.unwrap_or(mmr_start);
    let target = target_arg.unwrap_or(chain_tip);

    // Validate range
    if from_height < mmr_start {
        bail!("--from {from_height} is before Heartwood activation ({mmr_start})");
    }
    if from_height > target {
        bail!("--from {from_height} is greater than --target {target}");
    }

    println!("Chain tip: {chain_tip}");
    println!("Requested range: {from_height} → {target}");

    // Load existing state from SQLite
    let mut store = SqliteStore::open(db_path).await?;
    let mut tree = load_tree(&store);
    let existing_leaves = tree.as_ref().map(|t| leaf_count(t.len())).unwrap_or(0);
    let existing_height = mmr_start + existing_leaves;

    println!(
        "Stored: {} nodes ({existing_leaves} leaves, height {} → {})",
        store.len(),
        mmr_start,
        existing_height.saturating_sub(1).max(mmr_start)
    );

    // MMR is cumulative - --from requires the store to have all previous blocks
    let from_leaf = from_height - mmr_start;
    let target_leaves = target - mmr_start;

    // If --from was explicitly provided, verify store has blocks up to from_height
    if from_arg.is_some() && existing_leaves < from_leaf {
        bail!(
            "Store only has blocks up to height {}. Cannot start from {}.\n\
             Sync without --from first, or use --from {}",
            existing_height.saturating_sub(1).max(mmr_start),
            from_height,
            existing_height
        );
    }

    let start_leaf = existing_leaves;

    if start_leaf >= target_leaves {
        println!("\n✓ Already synced to target!");
        print_tree_status(&tree, &store, &client, mmr_start).await?;
        return Ok(());
    }

    let blocks_to_sync = target_leaves - start_leaf;
    println!(
        "\nSyncing {blocks_to_sync} blocks ({} → {})...\n",
        mmr_start + start_leaf,
        target - 1
    );

    // Main sync loop
    let mut last_progress = std::time::Instant::now();
    for leaf_idx in start_leaf..target_leaves {
        let height = mmr_start + leaf_idx;

        // Fetch block data from RPC
        let (header, sapling_root, sapling_tx) = fetch_block(&client, height).await?;
        let node = node_data_from_header(&header, height, sapling_root, sapling_tx);

        // Append to tree and persist new nodes
        append_and_store(&mut tree, &mut store, node)?;

        // Verify root and flush periodically
        let leaf_num = leaf_idx + 1;
        if leaf_num.is_multiple_of(VERIFY_INTERVAL) {
            verify_and_print(&tree, &client, mmr_start + leaf_num).await?;
            // Flush cache to DB to persist progress
            store.flush().await.ok();
        }

        // Progress indicator
        if last_progress.elapsed().as_secs() >= 1 {
            let pct = leaf_num as f64 / target_leaves as f64 * 100.0;
            print!("\rHeight {height} ({pct:.1}%) - {} nodes", store.len());
            std::io::stdout().flush()?;
            last_progress = std::time::Instant::now();
        }
    }

    // Final flush
    store.flush().await?;
    
    println!("\n\n✓ Sync complete!");
    print_tree_status(&tree, &store, &client, mmr_start).await
}

// ============ Tree Operations ============

/// Load tree from SQLite by replaying leaf nodes
fn load_tree(store: &SqliteStore) -> Option<Tree<V1>> {
    let mut tree: Option<Tree<V1>> = None;
    for pos in 0..store.len() {
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
        bail!("Root mismatch at {height}!");
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

fn root_hex(tree: &Tree<V1>) -> String {
    let mut root = compute_root(tree).unwrap();
    root.reverse();
    hex::encode(root)
}

fn leaf_count(tree_size: u32) -> u32 {
    (0..tree_size).filter(|&p| is_leaf_pos(p)).count() as u32
}

fn is_leaf_pos(pos: u32) -> bool {
    pos_height(pos) == 0
}

fn pos_height(mut pos: u32) -> u32 {
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

async fn fetch_block(
    client: &reqwest::Client,
    height: u32,
) -> Result<(BlockHeader, [u8; 32], u64)> {
    let hash = rpc(client, "getblockhash", serde_json::json!([height]))
        .await?
        .as_str()
        .unwrap()
        .to_string();

    let hdr_hex = rpc(client, "getblockheader", serde_json::json!([&hash, false]))
        .await?
        .as_str()
        .unwrap()
        .to_string();
    let header = BlockHeader::read(&mut hex::decode(&hdr_hex)?.as_slice())
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;

    let blk = rpc(client, "getblock", serde_json::json!([&hash, 2])).await?;

    let mut sapling_root = [0u8; 32];
    sapling_root.copy_from_slice(&hex::decode(blk["finalsaplingroot"].as_str().unwrap())?);
    sapling_root.reverse();

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
