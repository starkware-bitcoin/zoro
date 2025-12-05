//! Zcash FlyClient MMR (ZIP-221)

mod branch;
mod proof;
mod proof_generator;
mod store;

pub use branch::{activation_height, branch_id, branch_id_for_height};
pub use proof::ZcashInclusionProof;
pub use proof_generator::generate_proof;
pub use store::{MemoryStore, NodeStore, SqliteStore};

use primitive_types::U256;
use zcash_primitives::block::BlockHeader;

// Re-export zcash_history types for consumers
pub use zcash_history::{Entry, EntryLink, NodeData, Tree, Version, V1};
pub use zcash_primitives::block::BlockHash;

/// Compute work from compact bits (nBits)
pub fn work_from_bits(bits: u32) -> U256 {
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

/// Create NodeData from a block header (zcash_primitives)
pub fn node_data_from_header(
    header: &BlockHeader,
    height: u32,
    sapling_root: [u8; 32],
    sapling_tx: u64,
) -> NodeData {
    node_data_from_parts(
        header.hash().0,
        height,
        header.time,
        header.bits,
        sapling_root,
        sapling_tx,
    )
}

/// Create NodeData from raw block data (framework-agnostic)
pub fn node_data_from_parts(
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

/// Compute the FlyClient root hash from a tree
pub fn compute_root(tree: &Tree<V1>) -> Option<[u8; 32]> {
    tree.root_node().ok().map(|n| V1::hash(n.data()))
}

/// Append a leaf node directly to the store (no in-memory tree needed).
///
/// This function computes the necessary parent nodes mathematically and only
/// reads O(log n) nodes from the store - the left siblings needed for merging.
pub fn append_leaf(store: &mut impl NodeStore, leaf: NodeData) {
    let mut pos = store.len();
    let mut current = leaf;

    // Store the leaf
    store.set(pos, current.clone());
    pos += 1;

    // Merge with left siblings while we're completing pairs
    let mut height = 0u32;
    while pos_height(pos) > height {
        // We need to merge: find left sibling
        let left_pos = pos - (1 << (height + 1));
        let left = store.get(left_pos).expect("left sibling must exist");

        // Combine into parent
        current = combine_nodes(&left, &current);
        store.set(pos, current.clone());
        pos += 1;
        height += 1;
    }
}

/// Combine two nodes into a parent node using zcash_history's V1 protocol
fn combine_nodes(left: &NodeData, right: &NodeData) -> NodeData {
    V1::combine(left, right)
}

/// Compute the MMR root hash directly from the store (no full tree load).
///
/// Returns None if the store is empty.
pub fn compute_root_from_store(store: &impl NodeStore) -> Option<[u8; 32]> {
    let size = store.len();
    if size == 0 {
        return None;
    }

    // Find the peaks (roots of complete subtrees) and bag them
    let peaks = get_peak_positions(size);
    if peaks.is_empty() {
        return None;
    }

    // Get peak nodes
    let mut peak_nodes: Vec<NodeData> = peaks.iter().filter_map(|&pos| store.get(pos)).collect();

    if peak_nodes.is_empty() {
        return None;
    }

    // Bag peaks from right to left
    while peak_nodes.len() > 1 {
        let right = peak_nodes.pop().unwrap();
        let left = peak_nodes.pop().unwrap();
        peak_nodes.push(combine_nodes(&left, &right));
    }

    Some(V1::hash(&peak_nodes[0]))
}

/// Get positions of all peaks in an MMR of given size
fn get_peak_positions(size: u32) -> Vec<u32> {
    let mut peaks = Vec::new();
    let mut pos = 0u32;
    let mut remaining = size;

    while remaining > 0 {
        // Find the largest perfect tree that fits
        let height = (32 - remaining.leading_zeros()) - 1;
        let tree_size = (1u32 << (height + 1)) - 1;

        if tree_size <= remaining {
            // Peak is at position pos + tree_size - 1
            peaks.push(pos + tree_size - 1);
            pos += tree_size;
            remaining -= tree_size;
        } else {
            // Tree doesn't fit, try smaller
            break;
        }
    }

    peaks
}

/// Generate an inclusion proof for a block given its hash.
///
/// # Arguments
/// * `store` - Any store implementing `NodeStore` trait
/// * `block_hash` - The 32-byte block hash to prove inclusion for
///
/// # Returns
/// * `Ok((proof, root))` - The inclusion proof and the current tree root
/// * `Err` - If the block is not found or proof generation fails
///
/// # Example
/// ```ignore
/// let store = SqliteStore::open("mmr.db")?;
/// let block_hash = hex::decode("00000000010fbfbe...")?;
/// let (proof, root) = proof_for_block_hash(&store, &block_hash)?;
/// assert!(proof.verify(&root));
/// ```
pub fn proof_for_block_hash(
    store: &impl NodeStore,
    block_hash: &[u8; 32],
) -> Result<(ZcashInclusionProof, [u8; 32]), String> {
    let tree = load_tree_from_store(store).ok_or("No tree data in store")?;
    let leaf_count = count_leaves(tree.len());
    let leaf_index = find_block_by_hash(store, block_hash)?;
    let proof = generate_proof(&tree, leaf_index, leaf_count)?;
    let root = compute_root(&tree).ok_or("Failed to compute root")?;
    Ok((proof, root))
}

/// Generate an inclusion proof for a block at a specific height.
///
/// # Arguments
/// * `store` - Any store implementing `NodeStore` trait
/// * `height` - The block height (must be >= Heartwood activation height)
///
/// # Returns
/// * `Ok((proof, root))` - The inclusion proof and the current tree root
/// * `Err` - If the height is out of range or proof generation fails
pub fn proof_for_height(
    store: &impl NodeStore,
    height: u32,
) -> Result<(ZcashInclusionProof, [u8; 32]), String> {
    let start_height = activation_height::HEARTWOOD;

    if height < start_height {
        return Err(format!(
            "Height {height} is before Heartwood activation ({start_height})"
        ));
    }

    let tree = load_tree_from_store(store).ok_or("No tree data in store")?;
    let leaf_count = count_leaves(tree.len());
    let leaf_index = height - start_height;

    if leaf_index >= leaf_count {
        return Err(format!(
            "Height {height} not synced. Tree only has blocks up to {}",
            start_height + leaf_count - 1
        ));
    }

    let proof = generate_proof(&tree, leaf_index, leaf_count)?;
    let root = compute_root(&tree).ok_or("Failed to compute root")?;

    Ok((proof, root))
}

/// Load tree from any NodeStore by replaying leaf nodes.
/// Note: This is only needed for proof generation. For appending, use `append_leaf` instead.
pub fn load_tree_from_store(store: &impl NodeStore) -> Option<Tree<V1>> {
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

/// Find a block by its hash, returning its leaf index
fn find_block_by_hash(store: &impl NodeStore, block_hash: &[u8; 32]) -> Result<u32, String> {
    let mut leaf_index = 0u32;
    for pos in 0..store.len() {
        if is_leaf_pos(pos) {
            if let Some(node) = store.get(pos) {
                // For leaf nodes, subtree_commitment contains the block hash
                if &node.subtree_commitment == block_hash {
                    return Ok(leaf_index);
                }
                leaf_index += 1;
            }
        }
    }
    Err(format!(
        "Block {} not found in tree",
        hex::encode(block_hash)
    ))
}

/// Count leaf nodes in an MMR of given size
fn count_leaves(tree_size: u32) -> u32 {
    (0..tree_size).filter(|&p| is_leaf_pos(p)).count() as u32
}

/// Check if MMR position is a leaf (height 0)
fn is_leaf_pos(pos: u32) -> bool {
    pos_height(pos) == 0
}

/// Compute height of node at given MMR position
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

#[cfg(test)]
mod tests;
