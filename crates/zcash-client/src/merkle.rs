use std::sync::Arc;
use zebra_chain::block::merkle::Root;
use zebra_chain::transaction::Transaction;
use sha2::{Sha256, Digest};

/// Represents a block's transaction Merkle tree
#[derive(Debug)]
pub struct MerkleTree {
    pub root: Root,
    pub transactions: Vec<Arc<Transaction>>,
}

/// A Merkle inclusion proof for a transaction
#[derive(Debug, Clone)]
pub struct MerkleProof {
    /// The root of the Merkle tree
    pub root: Root,
    /// The authentication path (sibling hashes)
    pub path: Vec<[u8; 32]>,
    /// The index of the transaction in the block
    pub index: usize,
}

impl MerkleTree {
    /// Creates a new MerkleTree from a list of transactions and verifies the root
    pub fn new(transactions: Vec<Arc<Transaction>>, expected_root: Root) -> Result<Self, String> {
        let calculated_root: Root = transactions.iter().collect();

        if calculated_root != expected_root {
            return Err(format!(
                "Merkle root mismatch: expected {:?}, calculated {:?}",
                expected_root, calculated_root
            ));
        }

        Ok(Self {
            root: calculated_root,
            transactions,
        })
    }

    /// Generates a Merkle inclusion proof for the transaction at the given index
    pub fn generate_proof(&self, tx_index: usize) -> Result<MerkleProof, String> {
        if tx_index >= self.transactions.len() {
            return Err("Transaction index out of bounds".to_string());
        }

        let mut current_layer: Vec<[u8; 32]> = self.transactions
            .iter()
            .map(|tx| tx.hash().into())
            .collect();
        
        let mut path = Vec::new();
        let mut current_index = tx_index;

        // Continue until we reach the root (layer size 1)
        while current_layer.len() > 1 {
            let is_right_child = current_index % 2 != 0;
            
            let sibling_index = if is_right_child {
                current_index - 1
            } else {
                // If current is left child, sibling is right.
                // If right doesn't exist (odd layer length), duplicate left (self).
                (current_index + 1).min(current_layer.len() - 1)
            };

            path.push(current_layer[sibling_index]);

            // Compute parent layer
            current_layer = current_layer
                .chunks(2)
                .map(|chunk| {
                    match chunk {
                        [left, right] => double_sha256(left, right),
                        [left] => double_sha256(left, left), // Handle odd last element
                        _ => unreachable!("Chunk size is at most 2"),
                    }
                })
                .collect();
            
            current_index /= 2;
        }

        Ok(MerkleProof {
            root: self.root,
            path,
            index: tx_index,
        })
    }
}

impl MerkleProof {
    /// Verifies the proof against a transaction hash
    pub fn verify(&self, tx_hash: [u8; 32]) -> bool {
        let mut current = tx_hash;
        let mut index = self.index;

        for sibling in &self.path {
            let (left, right) = if index % 2 == 0 {
                (current, *sibling)
            } else {
                (*sibling, current)
            };
            
            current = double_sha256(&left, &right);
            index /= 2;
        }
        
        Root(current) == self.root
    }
}

/// Helper function to compute SHA256d (double SHA256)
fn double_sha256(l: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(l);
    hasher.update(r);
    let h1 = hasher.finalize();
    
    let mut hasher2 = Sha256::new();
    hasher2.update(h1);
    hasher2.finalize().into()
}
