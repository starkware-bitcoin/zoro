//! Zcash blockchain indexer that builds header state

use std::{path::PathBuf, sync::Arc};

use accumulators::{
    hasher::flyclient::{encode_node_data, ZcashFlyclientHasher},
    mmr::MMR,
    store::{sqlite::SQLiteStore, SubKey},
};
use primitive_types::U256;
use tokio::sync::broadcast;
use tracing::{debug, error, info};
use zcash_history::NodeData;
use zebra_chain::block::Hash as BlockHash;
use zoro_zcash_client::ZcashClient;

use crate::{
    chain_state::{ChainStateManager, ChainStateStore},
    store::AppStore,
};

/// Heartwood activation height (mainnet)
const HEARTWOOD_ACTIVATION: u32 = 903_000;

/// Branch IDs for different network upgrades
mod branch_id {
    pub const HEARTWOOD: u32 = 0xf5b9230b;
    pub const CANOPY: u32 = 0xe9ff75a6;
    pub const NU5: u32 = 0xc2d6d0b4;
}

/// Convert zebra BlockHash to [u8; 32]
fn block_hash_to_bytes(hash: &BlockHash) -> [u8; 32] {
    hash.0
}

/// Get branch ID for a given block height
fn branch_id_for_height(height: u32) -> u32 {
    if height >= 1_687_104 {
        branch_id::NU5
    } else if height >= 1_046_400 {
        branch_id::CANOPY
    } else {
        branch_id::HEARTWOOD
    }
}

/// Compute work from compact bits (nBits)
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

/// Create NodeData from raw block data
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

/// Zcash block indexer that builds FlyClient MMR accumulator
pub struct Indexer {
    /// Indexer configuration
    config: IndexerConfig,
    /// Shutdown signal receiver
    rx_shutdown: broadcast::Receiver<()>,
}

#[derive(Debug, Clone)]
pub struct IndexerConfig {
    /// Zcash RPC URL
    pub rpc_url: String,
    /// Zcash RPC user:password (optional)
    pub rpc_userpwd: Option<String>,
    /// ID
    pub id: String,
    /// Path to the database storing the header state
    pub db_path: PathBuf,
    /// Indexing lag in blocks
    pub indexing_lag: u32,
}

impl Indexer {
    pub fn new(config: IndexerConfig, rx_shutdown: broadcast::Receiver<()>) -> Self {
        Self {
            config,
            rx_shutdown,
        }
    }

    async fn run_inner(&mut self) -> Result<(), anyhow::Error> {
        info!("Block indexer started");

        let mut zcash_client =
            ZcashClient::new(self.config.rpc_url.clone(), self.config.rpc_userpwd.clone()).await?;
        info!("Zcash RPC client initialized");

        // We need to specify id to have deterministic keys in the database
        let id = Some(self.config.id.clone());
        let store =
            Arc::new(AppStore::single_atomic_writer(&self.config.db_path, id.clone()).await?);

        let mut next_block_height = match store.get_latest_chain_state_height().await {
            Ok(height) => height + 1,
            _ => 0,
        };

        let mut chain_state_mgr =
            ChainStateManager::restore(store.clone(), next_block_height).await?;
        info!("Chain state manager initialized");

        // Initialize FlyClient MMR if configured
        let flyclient_mmr = {
            let fc_store = SQLiteStore::new(
                self.config.db_path.to_str().unwrap(),
                Some(true),
                Some("flyclient"),
            )
            .await
            .map_err(|e| anyhow::anyhow!("Failed to open FlyClient store: {e}"))?;

            let hasher = Arc::new(ZcashFlyclientHasher);
            let mmr = MMR::new(Arc::new(fc_store), hasher, Some("flyclient".to_string()));

            let leaves = mmr.leaves_count.get().await.unwrap_or(0);
            info!(
                "FlyClient MMR initialized at {:?} ({} leaves)",
                self.config.db_path, leaves
            );
            mmr
        };

        // Wrap in Option<Arc<Mutex>> for mutable access
        let flyclient_mmr = Arc::new(tokio::sync::Mutex::new(flyclient_mmr));

        loop {
            tokio::select! {
                res = zcash_client.wait_block_header(next_block_height, self.config.indexing_lag) => {
                    match res {
                        Ok((block_header, block_hash)) => {
                            store.begin().await?;
                            chain_state_mgr.update(next_block_height, &block_header).await.map_err(|e| anyhow::anyhow!("Failed to update chain state: {e}"))?;
                            store.commit().await?;

                            // Process FlyClient MMR for Heartwood+ blocks

                                if next_block_height >= HEARTWOOD_ACTIVATION {
                                    let (sapling_root, sapling_tx) = zcash_client
                                        .get_block_flyclient_data(next_block_height)
                                        .await
                                        .map_err(|e| anyhow::anyhow!("Failed to get FlyClient data: {e}"))?;

                                    let bits = u32::from_be_bytes(
                                        block_header.difficulty_threshold.bytes_in_display_order(),
                                    );
                                    let node = node_data_from_parts(
                                        block_hash_to_bytes(&block_hash),
                                        next_block_height,
                                        block_header.time.timestamp() as u32,
                                        bits,
                                        sapling_root,
                                        sapling_tx,
                                    );

                                    // Append to FlyClient MMR
                                    let mut mmr = flyclient_mmr.lock().await;
                                    mmr.append(encode_node_data(&node)).await
                                        .map_err(|e| anyhow::anyhow!("Failed to append to FlyClient MMR: {e}"))?;

                                    // Verify root every 10 blocks
                                    let leaves = mmr.leaves_count.get().await.unwrap_or(0);
                                    if leaves % 10 == 0 || leaves <= 5 {
                                        if let Some(our_root) = mmr.root_hash.get(SubKey::None).await.ok().flatten() {
                                            // Get expected root from RPC (blockcommitments at next block)
                                            let verify_height = HEARTWOOD_ACTIVATION + leaves as u32;
                                            match zcash_client.get_block_commitment(verify_height).await {
                                                Ok(expected) => {
                                                    if our_root == expected {
                                                        info!("FlyClient root ✓ at height {} ({} leaves)", verify_height, leaves);
                                                    } else {
                                                        error!("FlyClient root MISMATCH at height {}!", verify_height);
                                                        error!("  Our root: {}", our_root);
                                                        error!("  Expected: {}", expected);
                                                    }
                                                }
                                                Err(e) => {
                                                    debug!("Could not verify FlyClient root: {e}");
                                                }
                                            }
                                        }
                                    }

                                    debug!("FlyClient MMR updated for block #{}", next_block_height);
                                }


                            info!("Block #{} {} processed", next_block_height, block_hash);
                            next_block_height += 1;
                        },
                        Err(e) => {
                            return Err(e.into())
                        }
                    }
                },
                _ = self.rx_shutdown.recv() => {
                    return Ok(())
                }
            }
        }
    }

    pub async fn run(&mut self) -> Result<(), ()> {
        match self.run_inner().await {
            Err(err) => {
                error!("Block indexer exited: {}", err);
                Err(())
            }
            Ok(()) => {
                info!("Block indexer terminated");
                Ok(())
            }
        }
    }
}
