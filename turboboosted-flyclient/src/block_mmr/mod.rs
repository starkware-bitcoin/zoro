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
use zcash_history::{Entry, NodeData, Tree, Version, V1};
use zcash_primitives::block::BlockHeader;

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

/// Create NodeData from a block header
pub fn node_data_from_header(
    header: &BlockHeader,
    height: u32,
    sapling_root: [u8; 32],
    sapling_tx: u64,
) -> NodeData {
    let branch_id = branch_id_for_height(height);
    let work = work_from_bits(header.bits);
    let mut wb = [0u8; 32];
    work.to_little_endian(&mut wb);
    NodeData {
        consensus_branch_id: branch_id,
        subtree_commitment: header.hash().0,
        start_time: header.time,
        end_time: header.time,
        start_target: header.bits,
        end_target: header.bits,
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

/// Load tree from any NodeStore by replaying leaf nodes
fn load_tree_from_store(store: &impl NodeStore) -> Option<Tree<V1>> {
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
