//! HTTP RPC server providing REST endpoints for proof generation and block count queries.

use accumulators::{
    hasher::flyclient::ZcashFlyclientHasher,
    mmr::{
        elements_count_to_leaf_count, leaf_count_to_mmr_size, map_leaf_index_to_element_index,
        ProofOptions, MMR,
    },
};
use hex::FromHex;
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tracing::{error, info};
use zoro_zcash_client::ZcashClient;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc};
use tower_http::{compression::CompressionLayer, cors::CorsLayer, trace::TraceLayer};
use zebra_chain::{block::Header, transaction::Hash};

use zoro_spv_verify::{ChainState, TransactionInclusionProof};

use crate::{chain_state::ChainStateStore, store::AppStore};

/// Query parameters for block inclusion proof generation and roots retrieval
#[derive(Debug, Deserialize)]
pub struct ChainHeightQuery {
    pub chain_height: Option<u32>,
}
/// Proof data structure for demonstrating inclusion of a block in the MMR
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockInclusionProof {
    /// MMR peak hashes at the time of proof generation
    pub peaks_hashes: Vec<String>,
    /// Sibling hashes needed to reconstruct the path to the root
    pub siblings_hashes: Vec<String>,
    /// Leaf index of the block in the MMR (same as block height)
    pub leaf_index: usize,
    /// Total number of leaves in the MMR
    pub leaf_count: usize,
}

/// Query parameters for block headers retrieval
#[derive(Debug, Deserialize)]
pub struct BlockHeadersQuery {
    pub offset: Option<u32>,
    pub size: Option<u32>,
}

/// Configuration for the RPC server
#[derive(Clone)]
pub struct RpcConfig {
    /// Host and port binding for the RPC server (e.g., "127.0.0.1:5000")
    pub rpc_host: String,
    /// ID
    pub id: String,
    /// Path to the database storing the header state
    pub db_path: PathBuf,
    /// Zcash RPC URL
    pub rpc_url: String,
    /// Zcash RPC user:password (optional)
    pub rpc_userpwd: Option<String>,
}

/// HTTP RPC server that provides endpoints for header state operations
pub struct RpcServer {
    config: RpcConfig,
    rx_shutdown: broadcast::Receiver<()>,
}

#[derive(Debug, Clone)]
pub struct AppState {
    store: Arc<AppStore>,
    zcash_client: Arc<ZcashClient>,
    flyclient_mmr: Arc<MMR>,
}

impl AppState {
    pub async fn new(config: RpcConfig) -> Result<Self, anyhow::Error> {
        let id = Some(config.id.clone());
        let store = Arc::new(AppStore::multiple_concurrent_readers(
            &config.db_path,
            id.clone(),
        ));
        let hasher = ZcashFlyclientHasher;
        let mmr = MMR::new(
            store.clone(),
            Arc::new(hasher),
            Some(format!("flyclient_{}", config.id)),
        );
        let zcash_client =
            ZcashClient::new(config.rpc_url.clone(), config.rpc_userpwd.clone()).await?;
        Ok(Self {
            zcash_client: Arc::new(zcash_client),
            store: store.clone(),
            flyclient_mmr: Arc::new(mmr),
        })
    }
}

impl RpcServer {
    pub fn new(config: RpcConfig, rx_shutdown: broadcast::Receiver<()>) -> Self {
        Self {
            config,
            rx_shutdown,
        }
    }

    async fn run_inner(&self) -> Result<(), std::io::Error> {
        info!("Starting RPC server on {}", self.config.rpc_host);

        let app_state = AppState::new(self.config.clone())
            .await
            .map_err(std::io::Error::other)?;

        let app = Router::new()
            .route("/block-inclusion-proof/:block_height", get(generate_proof))
            .route("/head", get(get_head))
            .route("/headers", get(get_block_headers))
            .route("/transaction-proof/:tx_id", get(get_transaction_proof))
            .route("/block-header/:block_height", get(get_block_header))
            .route("/chain-state/:block_height", get(get_chain_state))
            .with_state(app_state)
            .layer(CompressionLayer::new())
            .layer(CorsLayer::permissive())
            .layer(TraceLayer::new_for_http());

        let listener = TcpListener::bind(&self.config.rpc_host).await?;
        let mut rx_shutdown = self.rx_shutdown.resubscribe();

        axum::serve(listener, app)
            .with_graceful_shutdown(async move { rx_shutdown.recv().await.unwrap_or_default() })
            .await
    }

    pub async fn run(&self) -> Result<(), ()> {
        match self.run_inner().await {
            Err(err) => {
                error!("RPC server exited: {}", err);
                Err(())
            }
            Ok(()) => {
                info!("RPC server terminated");
                Ok(())
            }
        }
    }
}

/// Generate an inclusion proof for a block at the specified height
///
/// # Arguments
/// * `block_height` - The block height to generate a proof for
/// * `chain_height` - The chain (MMR) height to generate a proof for (optional)
///
/// # Returns
/// * `Json<InclusionProof>` - The inclusion proof in JSON format
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If proof generation fails
pub async fn generate_proof(
    State(state): State<AppState>,
    Path(block_height): Path<u32>,
    Query(query): Query<ChainHeightQuery>,
) -> Result<Json<BlockInclusionProof>, StatusCode> {
    let element_index = map_leaf_index_to_element_index(block_height as usize);
    let options = ProofOptions {
        elements_count: query
            .chain_height
            .map(|c| leaf_count_to_mmr_size(c as usize + 1)),
        ..Default::default()
    };
    let proof = {
        let pr = state
            .flyclient_mmr
            .get_proof(element_index, Some(options))
            .await
            .map_err(|e| {
                error!(
                    "Failed to generate block proof for height {}: {}",
                    block_height, e
                );
                StatusCode::INTERNAL_SERVER_ERROR
            })?;
        let leaf_count = elements_count_to_leaf_count(pr.elements_count).map_err(|e| {
            error!(
                "Failed to generate block proof for height {}: {}",
                block_height, e
            );
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
        BlockInclusionProof {
            peaks_hashes: pr.peaks_hashes,
            siblings_hashes: pr.siblings_hashes,
            leaf_index: block_height as usize,
            leaf_count,
        }
    };
    Ok(Json(proof))
}

/// Get the current head (latest processed block height) from the DB
///
/// # Returns
/// * `Json<u32>` - The current block count in JSON format
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If getting block count fails
pub async fn get_head(State(state): State<AppState>) -> Result<Json<u32>, StatusCode> {
    let block_count = state
        .store
        .get_latest_chain_state_height()
        .await
        .map_err(|e| {
            error!("Failed to get block count: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    Ok(Json(block_count - 1))
}

/// Get a block header by block height
///
/// # Arguments
/// * `block_height` - The block height to get the header for
///
/// # Returns
/// * `Json<BlockHeader>` - The block header in JSON format
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If fetching the block header fails
pub async fn get_block_header(
    State(state): State<AppState>,
    Path(block_height): Path<u32>,
) -> Result<Json<Header>, StatusCode> {
    let block_header = state
        .store
        .get_block_headers(block_height, 1)
        .await
        .map_err(|e| {
            error!(
                "Failed to get block header for height {}: {}",
                block_height, e
            );
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .pop()
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(block_header))
}

/// Get a range of block headers from the MMR
///
/// # Arguments
/// * `offset` - The starting block height to get the headers for
/// * `size` - The number of blocks to get the headers for
/// # Returns
/// * `Json<Vec<BlockHeader>>>` - The block headers in JSON format
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If fetching the block headers fails
pub async fn get_block_headers(
    State(state): State<AppState>,
    Query(query): Query<BlockHeadersQuery>,
) -> Result<Json<Vec<Header>>, StatusCode> {
    let offset = query.offset.unwrap_or(0);
    let size = query.size.unwrap_or(10);
    let block_headers = state
        .store
        .get_block_headers(offset, size)
        .await
        .map_err(|e| {
            error!(
                "Failed to get {} block headers for offset {}: {}",
                size, offset, e
            );
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    Ok(Json(block_headers))
}

/// Get a transaction inclusion proof for a specific transaction
///
/// # Returns
/// * `Json<TransactionInclusionProof>` - The transaction inclusion proof in JSON format
/// * `StatusCode::BAD_REQUEST` - If the transaction ID is invalid
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If proof generation fails
pub async fn get_transaction_proof(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> Result<Json<TransactionInclusionProof>, StatusCode> {
    let txid = Hash::from_hex(&tx_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let block_height = state
        .zcash_client
        .get_transaction_block_height(&txid)
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    let block_header = state
        .store
        .get_block_headers(block_height, 1)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .pop()
        .ok_or(StatusCode::NOT_FOUND)?;

    let block_merkle_tree = state
        .zcash_client
        .build_block_merkle_tree(block_height)
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    let tx_index = block_merkle_tree
        .get_transaction_index(txid)
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    let proof = block_merkle_tree
        .generate_proof(tx_index)
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    let tx = state
        .zcash_client
        .get_transaction(&txid)
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    let obj = TransactionInclusionProof {
        transaction: tx,
        transaction_proof: proof,
        block_header,
        block_height,
    };

    Ok(Json(obj))
}

/// Get the chain state for a specific block height
///
/// # Returns
/// * `Json<ChainState>` - The chain state in JSON format
/// * `StatusCode::INTERNAL_SERVER_ERROR` - If fetching the chain state fails
pub async fn get_chain_state(
    State(state): State<AppState>,
    Path(block_height): Path<u32>,
) -> Result<Json<ChainState>, StatusCode> {
    let chain_state = state
        .store
        .get_chain_state(block_height)
        .await
        .map_err(|e| {
            error!(
                "Failed to get chain state for height {}: {}",
                block_height, e
            );
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    Ok(Json(chain_state))
}
