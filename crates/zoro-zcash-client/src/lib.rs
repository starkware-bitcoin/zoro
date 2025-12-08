//! Zcash RPC client for fetching block headers, transactions and chain information with retry logic.

use base64::{engine::general_purpose, Engine as _};
use jsonrpsee::core::client::ClientT;
use jsonrpsee::core::params::ArrayParams;
use jsonrpsee::http_client::{HeaderMap, HeaderValue, HttpClient};
use jsonrpsee::rpc_params;
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::time::Duration;
use thiserror::Error;
use tracing::{debug, info};
use zebra_chain::block::{Block, Hash as BlockHash, Header};
use zebra_chain::serialization::ZcashDeserialize;
use zebra_chain::transaction::{Hash as TxHash, Transaction};
pub mod merkle;
pub mod serialize;

pub use merkle::{MerkleProof, MerkleTree};

/// Error types for Zcash RPC client operations
#[derive(Error, Debug)]
pub enum ZcashClientError {
    /// RPC client errors
    #[error("RPC client error: {0}")]
    RpcClient(#[from] jsonrpsee::core::client::Error),
    /// Invalid HTTP header value
    #[error("Invalid HTTP header value")]
    InvalidHeader,
    /// Failed to decode hex response
    #[error("Failed to decode hex response: {0}")]
    HexDecode(#[from] hex::FromHexError),
    /// Failed to deserialize Zcash block header
    #[error("Failed to deserialize Zcash block header: {0}")]
    ZcashBlockHeaderDeserialize(#[from] zebra_chain::serialization::SerializationError),
    /// Failed to read Zcash block header
    #[error("Failed to read Zcash block header: {0}")]
    ZcashBlockHeaderRead(#[from] std::io::Error),
    /// Failed to read Zcash transaction
    #[error("Failed to read Zcash transaction: {0}")]
    ZcashTransactionRead(std::io::Error),
    /// Unsupported or unknown network reported by node
    #[error("Unsupported Zcash network: {0}")]
    UnsupportedNetwork(String),
    /// Failed to convert block hash
    #[error("Failed to convert block hash: {0}")]
    InvalidBlockHash(String),
    /// Failed to deserialize Zcash block
    #[error("Failed to deserialize Zcash block: {0}")]
    ZcashBlockDeserialize(zebra_chain::serialization::SerializationError),
    /// Merkle root mismatch
    #[error("Merkle root mismatch: expected {expected:?}, calculated {calculated:?}")]
    MerkleRootMismatch {
        expected: String,
        calculated: String,
    },
}

/// Default HTTP request timeout
pub const HTTP_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Default chain height update interval in seconds
pub const CHAIN_HEIGHT_UPDATE_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub struct ZcashClient {
    client: HttpClient,
    chain_height: u32,
    backoff: backoff::ExponentialBackoff,
}

impl ZcashClient {
    /// Create a new Zcash RPC client with default retry settings (exponential backoff)
    pub async fn new(url: String, userpwd: Option<String>) -> Result<Self, ZcashClientError> {
        let mut headers = HeaderMap::new();
        if let Some(userpwd) = userpwd {
            let creds = general_purpose::STANDARD.encode(userpwd);
            headers.insert(
                "Authorization",
                HeaderValue::from_str(&format!("Basic {creds}"))
                    .map_err(|_| ZcashClientError::InvalidHeader)?,
            );
        };

        let client = HttpClient::builder()
            .set_headers(headers)
            .request_timeout(HTTP_REQUEST_TIMEOUT)
            .build(url)?;

        let backoff = backoff::ExponentialBackoff::default();

        Ok(Self {
            client,
            backoff: backoff.clone(),
            chain_height: 0,
        })
    }

    async fn request<T: DeserializeOwned>(
        &self,
        method: &str,
        params: ArrayParams,
    ) -> Result<T, ZcashClientError> {
        request_with_retry(self.backoff.clone(), || async {
            self.client
                .request(method, params.clone())
                .await
                .map_err(Into::into)
        })
        .await
    }

    /// Get block hash by height
    pub async fn get_block_hash(&self, height: u32) -> Result<BlockHash, ZcashClientError> {
        self.request::<String>("getblockhash", rpc_params![height])
            .await
            .and_then(|s| {
                let mut bytes = hex::decode(&s)?;
                bytes.reverse();
                BlockHash::zcash_deserialize(&mut bytes.as_slice()).map_err(Into::into)
            })
    }

    /// Get block header by hash
    pub async fn get_block_header(&self, hash: &BlockHash) -> Result<Header, ZcashClientError> {
        self.request::<String>("getblockheader", rpc_params![hash.to_string(), false])
            .await
            .and_then(|header_hex| {
                let header_bytes = hex::decode(header_hex)?;
                let mut reader = header_bytes.as_slice();
                Header::zcash_deserialize(&mut reader).map_err(Into::into)
            })
    }

    /// Get block height by hash
    pub async fn get_block_height(&self, hash: &BlockHash) -> Result<u32, ZcashClientError> {
        let header_info: serde_json::Value = self
            .request("getblockheader", rpc_params![hash.to_string(), true])
            .await?;
        let block_height = decode_block_height(&header_info)?;
        Ok(block_height)
    }

    /// Get block header by height
    pub async fn get_block_header_by_height(
        &self,
        height: u32,
    ) -> Result<(Header, BlockHash), ZcashClientError> {
        let hash = self.get_block_hash(height).await?;
        let header = self.get_block_header(&hash).await?;
        Ok((header, hash))
    }

    pub async fn get_transaction_block_height(
        &self,
        txid: &TxHash,
    ) -> Result<u32, ZcashClientError> {
        let tx: Value = self
            .request("getrawtransaction", rpc_params![txid.to_string(), 1])
            .await?;

        let block_height = tx
            .get("height")
            .and_then(|h| h.as_u64())
            .map(|h| h as u32)
            .ok_or_else(|| {
                ZcashClientError::ZcashBlockHeaderRead(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "missing or invalid block height in getrawtransaction response",
                ))
            })?;

        Ok(block_height)
    }

    /// Get transaction by txid and hash of the block containing the transaction
    pub async fn get_transaction(&self, txid: &TxHash) -> Result<Transaction, ZcashClientError> {
        // get raw tx from rpc in json mode
        let tx: String = self
            .request("getrawtransaction", rpc_params![txid.to_string()])
            .await?;

        let tx_bytes = hex::decode(tx).unwrap();
        let transaction = Transaction::zcash_deserialize(&mut tx_bytes.as_slice()).unwrap();

        Ok(transaction)
    }

    /// Get transaction inclusion proof
    pub async fn get_transaction_inclusion_proof(
        &self,
        _txid: &[u8],
    ) -> Result<(), ZcashClientError> {
        unimplemented!();
        // self.request("gettxoutproof", rpc_params![[txid.to_string()]])
        //     .await
    }

    /// Get block by hash
    pub async fn get_block(&self, hash: &BlockHash) -> Result<Block, ZcashClientError> {
        let block_hex: String = self
            .request("getblock", rpc_params![hash.to_string(), 0])
            .await?;
        let block_bytes = hex::decode(block_hex)?;
        let block = Block::zcash_deserialize(&mut block_bytes.as_slice())
            .map_err(ZcashClientError::ZcashBlockDeserialize)?;
        Ok(block)
    }

    /// Build the tx merkle tree of a given block number. This is required for generating the tx inclusion proof.
    pub async fn build_block_merkle_tree(
        &self,
        block_height: u32,
    ) -> Result<MerkleTree, ZcashClientError> {
        let hash = self.get_block_hash(block_height).await?;
        let block = self.get_block(&hash).await?;

        MerkleTree::new(block.transactions.clone(), block.header.merkle_root).map_err(|e| {
            ZcashClientError::MerkleRootMismatch {
                expected: format!("{:?}", block.header.merkle_root),
                calculated: e, // Ideally parse e properly, but string error from module is fine for now
            }
        })
    }

    /// Get current chain height
    pub async fn get_chain_height(&self) -> Result<u32, ZcashClientError> {
        let result: u64 = self.request("getblockcount", rpc_params![]).await?;
        Ok(result as u32)
    }

    /// Wait for a block header at the given height.
    /// If the specified lag is non-zero, the function will wait till `lag` blocks are built on top of the expected block.
    pub async fn wait_block_header(
        &mut self,
        height: u32,
        lag: u32,
    ) -> Result<(Header, BlockHash), ZcashClientError> {
        while height > self.chain_height {
            self.chain_height = self.get_chain_height().await?.saturating_sub(lag);
            if height <= self.chain_height {
                debug!("New chain height: {}", self.chain_height);
                break;
            } else {
                tokio::time::sleep(CHAIN_HEIGHT_UPDATE_INTERVAL).await;
            }
        }
        self.get_block_header_by_height(height).await
    }

    /// Get block data needed for FlyClient MMR (sapling root and sapling tx count)
    pub async fn get_block_flyclient_data(
        &self,
        height: u32,
    ) -> Result<([u8; 32], u64), ZcashClientError> {
        let hash = self.get_block_hash(height).await?;
        let blk: Value = self
            .request("getblock", rpc_params![hash.to_string(), 2])
            .await?;

        // Extract finalsaplingroot (little-endian in RPC, we need to reverse)
        let sapling_root_hex = blk["finalsaplingroot"].as_str().ok_or_else(|| {
            ZcashClientError::ZcashBlockHeaderRead(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "missing finalsaplingroot in getblock response",
            ))
        })?;
        let mut sapling_root = [0u8; 32];
        let decoded = hex::decode(sapling_root_hex)?;
        sapling_root.copy_from_slice(&decoded);
        sapling_root.reverse();

        // Count sapling transactions (those with shielded spends or outputs)
        let sapling_tx = blk["tx"]
            .as_array()
            .map(|txs| {
                txs.iter()
                    .filter(|tx| {
                        tx.get("vShieldedSpend")
                            .and_then(|v| v.as_array())
                            .map_or(false, |a| !a.is_empty())
                            || tx
                                .get("vShieldedOutput")
                                .and_then(|v| v.as_array())
                                .map_or(false, |a| !a.is_empty())
                    })
                    .count() as u64
            })
            .unwrap_or(0);

        Ok((sapling_root, sapling_tx))
    }

    /// Get block commitment (FlyClient root) for a given height
    pub async fn get_block_commitment(&self, height: u32) -> Result<String, ZcashClientError> {
        let hash = self.get_block_hash(height).await?;
        let blk: Value = self
            .request("getblock", rpc_params![hash.to_string(), 1])
            .await?;

        let commitment = blk["blockcommitments"]
            .as_str()
            .ok_or_else(|| {
                ZcashClientError::ZcashBlockHeaderRead(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "missing blockcommitments in getblock response",
                ))
            })?
            .to_string();

        Ok(commitment)
    }
}

fn decode_block_height(header_info: &serde_json::Value) -> Result<u32, ZcashClientError> {
    header_info
        .get("height")
        .and_then(|h| h.as_u64())
        .map(|h| h as u32)
        .ok_or_else(|| {
            ZcashClientError::ZcashBlockHeaderRead(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "missing or invalid block height in getblockheader response",
            ))
        })
}

/// Execute a request with retry logic using exponential backoff
/// Only retries on unexpected HTTP errors (not 200 OK or 400 Bad Request)
async fn request_with_retry<F, Fut, T>(
    backoff: backoff::ExponentialBackoff,
    operation: F,
) -> Result<T, ZcashClientError>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, ZcashClientError>>,
{
    use backoff::{future::retry_notify, Error};

    retry_notify(
        backoff,
        || async {
            match operation().await {
                Ok(result) => Ok(result),
                Err(err) => {
                    // Check if this is a retryable HTTP error
                    if is_retryable_error(&err) {
                        Err(Error::transient(err))
                    } else {
                        Err(Error::permanent(err))
                    }
                }
            }
        },
        |err, duration| {
            info!("Request failed, retrying in {:?}: {}", duration, err);
        },
    )
    .await
}

/// Determines if an error should be retried - only retry HTTP errors (except bad request)
fn is_retryable_error(err: &ZcashClientError) -> bool {
    match err {
        // Only retry RPC client errors that are HTTP-related (transport, timeouts, server errors)
        ZcashClientError::RpcClient(rpc_err) => {
            use jsonrpsee::core::client::Error as RpcError;
            match rpc_err {
                // Only retry transport errors and timeouts (HTTP-level issues)
                RpcError::Transport(_) => true,
                RpcError::RequestTimeout => true,
                RpcError::RestartNeeded(_) => true,
                RpcError::ServiceDisconnect => true,
                // Don't retry any other RPC errors (JSON-RPC level issues, bad requests, etc.)
                _ => false,
            }
        }
        _ => false,
    }
}
