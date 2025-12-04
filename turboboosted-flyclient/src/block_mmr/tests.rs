//! Tests for the block MMR

use super::*;
use primitive_types::U256;
use zcash_history::{Entry, Tree};

const RPC_URL: &str = "https://rpc.mainnet.ztarknet.cash";

fn test_node(i: u32) -> NodeData {
    NodeData {
        consensus_branch_id: branch_id::HEARTWOOD,
        subtree_commitment: [(i + 1) as u8; 32],
        start_time: 1000 + i,
        end_time: 1000 + i,
        start_target: 0x1d00ffff,
        end_target: 0x1d00ffff,
        start_sapling_root: [0u8; 32],
        end_sapling_root: [0u8; 32],
        subtree_total_work: U256::from(100),
        start_height: (903_000 + i) as u64,
        end_height: (903_000 + i) as u64,
        sapling_tx: i as u64,
    }
}

fn build_tree(count: u32) -> Tree<V1> {
    let mut tree: Option<Tree<V1>> = None;
    for i in 0..count {
        let node = test_node(i);
        if let Some(inner_tree) = &mut tree {
            inner_tree.append_leaf(node).unwrap();
        } else {
            tree = Some(Tree::new(1, vec![(0, Entry::new_leaf(node))], vec![]));
        }
    }
    tree.unwrap()
}

#[test]
fn test_proof_verify() {
    let tree = build_tree(7);
    let root_hash = compute_root(&tree).unwrap();

    for leaf_idx in 0..7 {
        let proof = generate_proof(&tree, leaf_idx, 7).unwrap();
        assert!(proof.verify(&root_hash), "Proof for leaf {leaf_idx} failed",);
    }
}

#[test]
fn test_proof_serialization() {
    let tree = build_tree(3);
    let root_hash = compute_root(&tree).unwrap();
    let proof = generate_proof(&tree, 0, 3).unwrap();

    let json = proof.to_json().unwrap();
    let proof2 = ZcashInclusionProof::from_json(&json).unwrap();
    assert!(proof2.verify(&root_hash));
}

#[test]
fn test_branch_ids() {
    assert_eq!(branch_id_for_height(903_000), branch_id::HEARTWOOD);
    assert_eq!(branch_id_for_height(1_046_400), branch_id::CANOPY);
    assert_eq!(branch_id_for_height(1_687_104), branch_id::NU5);
}

#[test]
fn test_inclusion_proof_real_scenario() {
    // Build a tree with 100 blocks
    let block_count = 100u32;
    let tree = build_tree(block_count);
    let root_hash = compute_root(&tree).unwrap();

    // Test 1: Verify a random block in the middle (block 42)
    let random_idx = 42u32;
    let proof = generate_proof(&tree, random_idx, block_count).unwrap();

    assert_eq!(proof.block_height(), 903_000 + random_idx as u64);
    assert!(
        proof.verify(&root_hash),
        "Proof for existing block {random_idx} should verify",
    );

    // Test 2: Verify first and last blocks
    let first_proof = generate_proof(&tree, 0, block_count).unwrap();
    let last_proof = generate_proof(&tree, block_count - 1, block_count).unwrap();

    assert!(
        first_proof.verify(&root_hash),
        "First block proof should verify"
    );
    assert!(
        last_proof.verify(&root_hash),
        "Last block proof should verify"
    );

    // Test 3: Proof with wrong root should fail
    let wrong_root = [0xFFu8; 32];
    assert!(
        !proof.verify(&wrong_root),
        "Proof should fail with wrong root"
    );

    // Test 4: Tampered proof should fail (modify the leaf)
    let mut tampered_proof = proof.clone();
    tampered_proof.leaf.subtree_commitment = [0xDEu8; 32]; // Wrong block hash
    assert!(
        !tampered_proof.verify(&root_hash),
        "Tampered proof should fail verification"
    );

    // Test 5: Proof for non-existent block index should error
    let result = generate_proof(&tree, block_count + 10, block_count);
    assert!(
        result.is_err(),
        "Proof for out-of-bounds block should return error"
    );

    // Test 6: Fake block not in tree - create proof but with wrong leaf data
    let mut fake_proof = generate_proof(&tree, 50, block_count).unwrap();
    // Replace leaf with a block that was never inserted
    fake_proof.leaf = NodeData {
        consensus_branch_id: branch_id::HEARTWOOD,
        subtree_commitment: [0xABu8; 32], // Fake hash
        start_time: 9999,
        end_time: 9999,
        start_target: 0x1d00ffff,
        end_target: 0x1d00ffff,
        start_sapling_root: [0u8; 32],
        end_sapling_root: [0u8; 32],
        subtree_total_work: U256::from(100),
        start_height: 999_999, // Fake height
        end_height: 999_999,
        sapling_tx: 0,
    };
    assert!(
        !fake_proof.verify(&root_hash),
        "Fake block proof should fail verification"
    );

    println!("✓ All inclusion proof tests passed for {block_count} blocks",);
}

#[test]
fn test_proof_at_various_tree_sizes() {
    // Test proof generation at different tree sizes (edge cases)
    for size in [1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 100] {
        let tree = build_tree(size);
        let root = compute_root(&tree).unwrap();

        // Verify all blocks
        for i in 0..size {
            let proof = generate_proof(&tree, i, size)
                .unwrap_or_else(|e| panic!("Failed at size={size}, idx={i}: {e}"));
            assert!(
                proof.verify(&root),
                "Failed at tree size={size}, block index={i}",
            );
        }
    }
    println!("✓ Proofs verified at all tree sizes");
}

// ============ Mainnet RPC Tests ============

mod mainnet {
    use super::*;
    use zcash_primitives::block::BlockHeader;

    async fn rpc(
        client: &reqwest::Client,
        method: &str,
        params: serde_json::Value,
    ) -> anyhow::Result<serde_json::Value> {
        let resp: serde_json::Value = client
            .post(RPC_URL)
            .json(
                &serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
            )
            .send()
            .await?
            .json()
            .await?;
        Ok(resp["result"].clone())
    }

    async fn get_block_data(
        client: &reqwest::Client,
        height: u32,
    ) -> anyhow::Result<(BlockHeader, [u8; 32], u64)> {
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
        let hdr_bytes = hex::decode(&hdr_hex)?;
        let header =
            BlockHeader::read(&mut &hdr_bytes[..]).map_err(|e| anyhow::anyhow!("{e:?}",))?;

        // Get block for sapling root and tx count
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

    async fn get_expected_root(client: &reqwest::Client, height: u32) -> anyhow::Result<String> {
        let hash = rpc(client, "getblockhash", serde_json::json!([height]))
            .await?
            .as_str()
            .unwrap()
            .to_string();
        let blk = rpc(client, "getblock", serde_json::json!([&hash, 1])).await?;
        Ok(blk["blockcommitments"].as_str().unwrap().to_string())
    }

    #[tokio::test]
    async fn test_mainnet_real_blocks() {
        let client = reqwest::Client::new();
        let start_height = activation_height::HEARTWOOD;
        let block_count = 50u32;

        println!(
            "Fetching {block_count} real blocks from mainnet starting at height {start_height}..."
        );

        // Build tree with real blocks (in-memory)
        let mut tree: Option<Tree<V1>> = None;
        for i in 0..block_count {
            let height = start_height + i;
            let (header, sapling_root, sapling_tx) = get_block_data(&client, height).await.unwrap();
            let node = node_data_from_header(&header, height, sapling_root, sapling_tx);

            if tree.is_none() {
                tree = Some(Tree::new(1, vec![(0, Entry::new_leaf(node))], vec![]));
            } else {
                tree.as_mut().unwrap().append_leaf(node).unwrap();
            }

            if (i + 1).is_multiple_of(10) {
                print!(".");
                use std::io::Write;
                std::io::stdout().flush().unwrap();
            }
        }
        println!(" done!");

        let tree = tree.unwrap();
        let root_hash = compute_root(&tree).unwrap();

        // Verify against RPC
        let mut expected_root = root_hash;
        expected_root.reverse();
        let expected = get_expected_root(&client, start_height + block_count)
            .await
            .unwrap();
        let our_root = hex::encode(expected_root);

        assert_eq!(
            our_root, expected,
            "Root mismatch! expected {expected} but got {our_root}"
        );

        // Test 1: Generate and verify proof for a random block
        let random_idx = 25u32;
        let proof = generate_proof(&tree, random_idx, block_count).unwrap();
        println!(
            "\nBlock {} proof: {} siblings, {} peaks",
            start_height + random_idx,
            proof.siblings.len(),
            proof.peaks.len()
        );
        assert!(proof.verify(&root_hash), "Real block proof should verify");

        // Test 2: Verify serialization round-trip
        let json = proof.to_json().unwrap();
        let proof2 = ZcashInclusionProof::from_json(&json).unwrap();
        assert!(
            proof2.verify(&root_hash),
            "Deserialized proof should verify"
        );

        println!("Proof JSON size: {} bytes", json.len());

        // Test 3: Tampered proof should fail
        let mut tampered = proof.clone();
        tampered.leaf.subtree_commitment[0] ^= 0xFF;
        assert!(!tampered.verify(&root_hash), "Tampered proof should fail");

        // Test 4: Proof for fake block should fail
        let mut fake_proof = generate_proof(&tree, 10, block_count).unwrap();
        fake_proof.leaf = NodeData {
            consensus_branch_id: branch_id::HEARTWOOD,
            subtree_commitment: [0xDE; 32],
            start_time: 0,
            end_time: 0,
            start_target: 0,
            end_target: 0,
            start_sapling_root: [0; 32],
            end_sapling_root: [0; 32],
            subtree_total_work: U256::zero(),
            start_height: 999999,
            end_height: 999999,
            sapling_tx: 0,
        };
        assert!(!fake_proof.verify(&root_hash), "Fake block should fail");

        println!("\n✓ All mainnet proofs verified successfully!");
    }
}
