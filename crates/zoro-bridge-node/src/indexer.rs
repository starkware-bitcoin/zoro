//! Zcash blockchain indexer that builds header state

use std::{path::PathBuf, sync::Arc};

use tokio::sync::broadcast;
use tracing::{debug, error, info};

use zoro_zcash_client::ZcashClient;

use crate::{
    chain_state::{ChainStateManager, ChainStateStore},
    store::AppStore,
};
/// Zcash block indexer that builds header state and generates sparse roots
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
    /// Path to the FlyClient MMR database (optional)
    pub flyclient_db_path: Option<PathBuf>,
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

        // Initialize FlyClient MMR store if configured
        let mut flyclient_store = if let Some(ref path) = self.config.flyclient_db_path {
            let fc_store = SqliteStore::open(path.to_str().unwrap())
                .await
                .map_err(|e| anyhow::anyhow!("Failed to open FlyClient store: {e}"))?;
            info!(
                "FlyClient MMR store opened at {:?} ({} nodes)",
                path,
                fc_store.len()
            );
            Some(fc_store)
        } else {
            None
        };

        loop {
            tokio::select! {
                res = zcash_client.wait_block_header(next_block_height, self.config.indexing_lag) => {
                    match res {
                        Ok((block_header, block_hash)) => {
                            store.begin().await?;
                            chain_state_mgr.update(next_block_height, &block_header).await.map_err(|e| anyhow::anyhow!("Failed to update chain state: {e}"))?;
                            store.commit().await?;

                            // Process FlyClient MMR for Heartwood+ blocks
                            if let Some(ref mut fc_store) = flyclient_store {
                                if next_block_height >= activation_height::HEARTWOOD {
                                    let (sapling_root, sapling_tx) = bitcoin_client
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

                                    append_leaf(fc_store, node);
                                    debug!("FlyClient MMR updated for block #{}", next_block_height);
                                }
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
