//! Sync mainnet blocks to SQLite-backed MMR tree
//!
//! Usage: cargo run --bin sync [--db PATH] [--target HEIGHT]

use anyhow::Result;
use std::io::Write;
use turboboosted_flyclient::{
    activation_height, compute_root, node_data_from_header, NodeStore, SqliteStore,
};
use zcash_history::{Entry, EntryLink, Tree, V1};
use zcash_primitives::block::BlockHeader;

const RPC_URL: &str = "https://rpc.mainnet.ztarknet.cash";
const DEFAULT_DB: &str = "mmr.db";

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();

    let db_path = args
        .iter()
        .position(|a| a == "--db")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
        .unwrap_or(DEFAULT_DB);

    let target_height: Option<u32> = args
        .iter()
        .position(|a| a == "--target")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok());

    println!("Zcash FlyClient MMR Sync");
    println!("========================");
    println!("Database: {db_path}");
    println!("RPC: {RPC_URL}");

    let client = reqwest::Client::new();
    let start_height = activation_height::HEARTWOOD;

    // Get current chain tip if no target specified
    let chain_tip = get_chain_height(&client).await?;
    let target = target_height.unwrap_or(chain_tip);
    println!("Chain tip: {chain_tip}");
    println!("Target: {target}");

    // Open SQLite store
    let mut store = SqliteStore::open(db_path)?;
    println!("Stored nodes: {}", store.len());

    // Rebuild tree from stored nodes
    let mut tree: Option<Tree<V1>> = None;
    let existing_leaves = rebuild_tree_from_store(&store, &mut tree);
    println!("Existing leaves: {existing_leaves}");

    let blocks_needed = target.saturating_sub(start_height + existing_leaves);
    if blocks_needed == 0 {
        println!("\n✓ Already synced to target height!");
        print_status(&tree, &store, &client, start_height).await?;
        return Ok(());
    }

    println!("\nSyncing {blocks_needed} blocks...\n");

    const VERIFY_INTERVAL: u32 = 10; // Verify root every N blocks
    let mut last_print = std::time::Instant::now();

    for i in existing_leaves..(target - start_height) {
        let height = start_height + i;

        let (header, sapling_root, sapling_tx) = get_block_data(&client, height).await?;
        let node = node_data_from_header(&header, height, sapling_root, sapling_tx);

        if tree.is_none() {
            tree = Some(Tree::new(
                1,
                vec![(0, Entry::new_leaf(node.clone()))],
                vec![],
            ));
            store.set(0, node);
        } else {
            let appended = tree
                .as_mut()
                .unwrap()
                .append_leaf(node.clone())
                .map_err(|e| anyhow::anyhow!("{e:?}"))?;
            for link in appended {
                if let EntryLink::Stored(pos) = link {
                    if let Ok(entry) = tree.as_ref().unwrap().resolve_link(link) {
                        store.set(pos, entry.data().clone());
                    }
                }
            }
        }

        let leaf_num = i + 1;

        // Verify root every VERIFY_INTERVAL blocks
        if leaf_num % VERIFY_INTERVAL == 0 {
            let verify_height = start_height + leaf_num;
            let matches = verify_root(tree.as_ref().unwrap(), &client, verify_height).await?;
            let symbol = if matches { "✓" } else { "✗" };
            println!("Block {verify_height}: root {symbol}");
            if !matches {
                anyhow::bail!("Root mismatch at block {verify_height}!");
            }
        }

        // Progress every second
        if last_print.elapsed().as_secs() >= 1 {
            let progress = leaf_num as f64 / (target - start_height) as f64 * 100.0;
            print!(
                "\rHeight: {height} ({progress:.1}%) - {} nodes stored  ",
                store.len()
            );
            std::io::stdout().flush()?;
            last_print = std::time::Instant::now();
        }
    }

    println!("\n\n✓ Sync complete!");
    print_status(&tree, &store, &client, start_height).await?;

    Ok(())
}

async fn print_status(
    tree: &Option<Tree<V1>>,
    store: &SqliteStore,
    client: &reqwest::Client,
    start_height: u32,
) -> Result<()> {
    if let Some(tree) = tree {
        let leaf_count = count_leaves(tree.len());
        let root = compute_root(tree).unwrap();
        let mut root_le = root;
        root_le.reverse();

        println!("\nTree status:");
        println!("  Nodes: {}", tree.len());
        println!("  Leaves: {leaf_count}");
        println!("  Stored: {}", store.len());
        println!("  Root: {}", hex::encode(root_le));

        // Verify against RPC
        let verify_height = start_height + leaf_count;
        let expected = get_expected_root(client, verify_height).await?;
        let matches = hex::encode(root_le) == expected;
        println!(
            "  Matches block {verify_height}: {}",
            if matches { "✓" } else { "✗" }
        );
    }
    Ok(())
}

fn rebuild_tree_from_store(store: &SqliteStore, tree: &mut Option<Tree<V1>>) -> u32 {
    let len = store.len();
    if len == 0 {
        return 0;
    }

    for pos in 0..len {
        if let Some(node) = store.get(pos) {
            if is_leaf_pos(pos) {
                if tree.is_none() {
                    *tree = Some(Tree::new(1, vec![(0, Entry::new_leaf(node))], vec![]));
                } else {
                    tree.as_mut().unwrap().append_leaf(node).ok();
                }
            }
        }
    }

    tree.as_ref().map(|t| count_leaves(t.len())).unwrap_or(0)
}

fn count_leaves(tree_size: u32) -> u32 {
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
        let k = 32 - n.leading_zeros();
        let left_size = (1u32 << (k - 1)) - 1;
        pos -= left_size;
    }
}

// RPC helpers

async fn rpc(
    client: &reqwest::Client,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let resp: serde_json::Value = client
        .post(RPC_URL)
        .json(&serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
        .send()
        .await?
        .json()
        .await?;
    Ok(resp["result"].clone())
}

async fn get_chain_height(client: &reqwest::Client) -> Result<u32> {
    let info = rpc(client, "getblockchaininfo", serde_json::json!([])).await?;
    Ok(info["blocks"].as_u64().unwrap() as u32)
}

async fn get_block_data(
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
    let hdr_bytes = hex::decode(&hdr_hex)?;
    let header = BlockHeader::read(&mut &hdr_bytes[..]).map_err(|e| anyhow::anyhow!("{e:?}"))?;

    let blk = rpc(client, "getblock", serde_json::json!([&hash, 2])).await?;

    let mut sapling_root = [0u8; 32];
    let sr_hex = blk["finalsaplingroot"].as_str().unwrap();
    sapling_root.copy_from_slice(&hex::decode(sr_hex)?);
    sapling_root.reverse();

    let sapling_tx = blk["tx"]
        .as_array()
        .map(|txs| {
            txs.iter()
                .filter(|t| {
                    t["vShieldedSpend"]
                        .as_array()
                        .map(|a| !a.is_empty())
                        .unwrap_or(false)
                        || t["vShieldedOutput"]
                            .as_array()
                            .map(|a| !a.is_empty())
                            .unwrap_or(false)
                })
                .count() as u64
        })
        .unwrap_or(0);

    Ok((header, sapling_root, sapling_tx))
}

async fn get_expected_root(client: &reqwest::Client, height: u32) -> Result<String> {
    let hash = rpc(client, "getblockhash", serde_json::json!([height]))
        .await?
        .as_str()
        .unwrap()
        .to_string();
    let blk = rpc(client, "getblock", serde_json::json!([&hash, 1])).await?;
    Ok(blk["blockcommitments"].as_str().unwrap().to_string())
}

async fn verify_root(tree: &Tree<V1>, client: &reqwest::Client, height: u32) -> Result<bool> {
    let root = compute_root(tree).unwrap();
    let mut root_le = root;
    root_le.reverse();
    let our_root = hex::encode(root_le);
    let expected = get_expected_root(client, height).await?;
    Ok(our_root == expected)
}
