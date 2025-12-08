//! Zcash blockchain indexer that builds header state

use std::{path::PathBuf, sync::Arc};

use tokio::sync::broadcast;
use tracing::{error, info};

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

        loop {
            tokio::select! {
                res = zcash_client.wait_block_header(next_block_height, self.config.indexing_lag) => {
                    match res {
                        Ok((block_header, block_hash)) => {
                            store.begin().await?;
                            chain_state_mgr.update(next_block_height, &block_header).await.map_err(|e| anyhow::anyhow!("Failed to update chain state: {e}"))?;
                            store.commit().await?;
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
