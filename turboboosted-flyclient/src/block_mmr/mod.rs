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
use zcash_history::{NodeData, Version, V1};
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
pub fn compute_root(tree: &zcash_history::Tree<V1>) -> Option<[u8; 32]> {
    tree.root_node().ok().map(|n| V1::hash(n.data()))
}

#[cfg(test)]
mod tests;
