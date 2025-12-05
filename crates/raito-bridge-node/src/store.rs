use std::collections::HashMap;
use std::ops::DerefMut;
use std::path::Path;

use async_trait::async_trait;
use raito_spv_verify::ChainState;
use sqlx::pool::PoolConnection;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous,
    SqliteTransactionManager,
};
use sqlx::{Acquire, Pool, Row, Sqlite, SqliteConnection, SqlitePool, TransactionManager};
use thiserror::Error;
use tokio::fs;
use zebra_chain::block::Hash;
use zebra_chain::block::Header;
use zebra_chain::serialization::ZcashDeserialize;
use zebra_chain::serialization::ZcashSerialize;

use crate::chain_state::ChainStateStore;

/// An error that can occur when using the store.
#[derive(Error, Debug)]
pub enum StoreError {
    #[error("Fail to get value from store")]
    GetError,
    #[error("SQLite error: {0}")]
    SQLite(#[from] sqlx::Error),
    #[error("Custom error: {0:?}")]
    Custom(Box<dyn std::error::Error + Send + Sync + 'static>),
}

/// A key-value store backed by SQLite.
#[derive(Debug)]
pub struct SQLiteStore {
    id: Option<String>,
    pool: Pool<Sqlite>,
    atomic_set_many: bool,
}

// SQLite's default maximum number of variables per statement is 999.
// We use a smaller number to be safe.
const MAX_VARIABLE_NUMBER: usize = 900;

impl SQLiteStore {
    /// Create a new SQLite store with externally created pool.
    pub fn with_pool(pool: Pool<Sqlite>, id: Option<String>) -> Self {
        SQLiteStore {
            id,
            pool,
            atomic_set_many: false,
        }
    }

    /// Create a new SQLite store from a file path.
    pub async fn new(
        path: &str,
        create_file_if_not_exists: Option<bool>,
        id: Option<&str>,
    ) -> Result<Self, sqlx::Error> {
        let pool = if let Some(create_file_if_not_exists) = create_file_if_not_exists {
            let options = SqliteConnectOptions::new()
                .filename(path)
                .create_if_missing(create_file_if_not_exists);
            SqlitePool::connect_with(options).await?
        } else {
            SqlitePool::connect(path).await?
        };

        let store = SQLiteStore {
            id: id.map(|v| v.to_string()),
            pool,
            atomic_set_many: true,
        };
        store.init().await?;
        Ok(store)
    }

    /// Acquire a connection from the pool.
    /// NOTE: if there's no available connection this function will fail after acquire timeout.
    /// Configure it via sqlite options.
    pub async fn acquire_connection(&self) -> Result<PoolConnection<Sqlite>, sqlx::Error> {
        self.pool.acquire().await
    }

    /// Initialize the underlying key-value table.
    pub async fn init(&self) -> Result<(), sqlx::Error> {
        let mut conn = self.acquire_connection().await?;
        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS store (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );"#,
        )
        .execute(conn.deref_mut())
        .await?;
        Ok(())
    }

    pub fn id(&self) -> String {
        self.id.clone().unwrap_or_default()
    }

    pub async fn get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let mut conn = self.acquire_connection().await?;

        let row = sqlx::query("SELECT value FROM store WHERE key = ?")
            .bind(key)
            .fetch_optional(conn.deref_mut())
            .await?;

        if let Some(row) = row {
            let value: String = row.try_get("value")?;
            Ok(Some(value))
        } else {
            Ok(None)
        }
    }

    pub async fn get_many(&self, keys: Vec<&str>) -> Result<HashMap<String, String>, StoreError> {
        let mut conn = self.acquire_connection().await?;
        let mut map = HashMap::new();

        for key_chunk in keys.chunks(MAX_VARIABLE_NUMBER) {
            let placeholders = key_chunk.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
            let query_statement =
                format!("SELECT key, value FROM store WHERE key IN ({placeholders})");

            let mut query = sqlx::query(&query_statement);

            for key in key_chunk {
                query = query.bind(*key);
            }

            let rows = query.fetch_all(conn.deref_mut()).await?;
            for row in rows {
                let key: String = row.get("key");
                let value: String = row.get("value");
                map.insert(key, value);
            }
        }

        Ok(map)
    }

    pub async fn set(&self, key: &str, value: &str) -> Result<(), StoreError> {
        let mut conn = self.acquire_connection().await?;
        sqlx::query("INSERT OR REPLACE INTO store (key, value) VALUES (?, ?)")
            .bind(key)
            .bind(value)
            .execute(conn.deref_mut())
            .await?;

        Ok(())
    }

    pub async fn set_many(&self, entries: HashMap<String, String>) -> Result<(), StoreError> {
        let mut conn = self.acquire_connection().await?;
        match self.atomic_set_many {
            true => {
                let mut tx = conn.begin().await?;
                set_many(tx.deref_mut(), entries).await?;
                tx.commit().await.map_err(StoreError::SQLite)
            }
            false => set_many(conn.deref_mut(), entries).await,
        }
    }

    pub async fn delete(&self, key: &str) -> Result<(), StoreError> {
        let mut conn = self.acquire_connection().await?;
        sqlx::query("DELETE FROM store WHERE key = ?")
            .bind(key)
            .execute(conn.deref_mut())
            .await?;

        Ok(())
    }

    pub async fn delete_many(&self, keys: Vec<&str>) -> Result<(), StoreError> {
        let mut conn = self.acquire_connection().await?;

        for key_chunk in keys.chunks(MAX_VARIABLE_NUMBER) {
            let placeholders = key_chunk.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
            let query_statement = format!("DELETE FROM store WHERE key IN ({placeholders})");

            let mut query = sqlx::query(&query_statement);

            for key in key_chunk {
                query = query.bind(*key);
            }

            query.execute(conn.deref_mut()).await?;
        }

        Ok(())
    }
}

async fn set_many(
    executor: &mut SqliteConnection,
    entries: HashMap<String, String>,
) -> Result<(), StoreError> {
    for entry_chunk in entries
        .iter()
        .collect::<Vec<_>>()
        .chunks(MAX_VARIABLE_NUMBER)
    {
        let mut query = String::from("INSERT OR REPLACE INTO store (key, value) VALUES ");
        let placeholders = entry_chunk
            .iter()
            .map(|_| "(?, ?)")
            .collect::<Vec<_>>()
            .join(", ");
        query.push_str(&placeholders);

        let mut sqlx_query = sqlx::query(&query);
        for (key, value) in entry_chunk {
            sqlx_query = sqlx_query.bind(key).bind(value);
        }

        sqlx_query.execute(&mut *executor).await?;
    }
    Ok(())
}

/// SQLite busy timeout in milliseconds
const SQLITE_BUSY_TIMEOUT: &str = "5000";

/// Maximum number of concurrent readers (size of the connection pool)
const SQLITE_MAX_CONCURRENT_READERS: u32 = 10;

/// SQLite-backed store with single-writer and multi-reader pools.
/// - WAL mode for concurrent readers during writes
/// - Single writer (max_connections = 1)
/// - Optional active write transaction encapsulated in the store
#[derive(Debug)]
pub struct AppStore(SQLiteStore);

impl AppStore {
    /// Create a store for a single atomic writer
    pub async fn single_atomic_writer<P: AsRef<Path>>(
        path: P,
        id: Option<String>,
    ) -> Result<Self, sqlx::Error> {
        if let Some(parent) = path.as_ref().parent() {
            fs::create_dir_all(parent).await?;
        }

        let options = SqliteConnectOptions::new()
            .filename(path.as_ref())
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal)
            .pragma("busy_timeout", SQLITE_BUSY_TIMEOUT);

        // Writer pool: single connection ensures single-writer semantics
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;

        let store = Self(SQLiteStore::with_pool(pool, id));
        store.init().await?;

        Ok(store)
    }

    /// Create a store for multiple concurrent readers
    pub fn multiple_concurrent_readers<P: AsRef<Path>>(path: P, id: Option<String>) -> Self {
        let options = SqliteConnectOptions::new()
            .filename(path.as_ref())
            .read_only(true);

        let pool = SqlitePoolOptions::new()
            .max_connections(SQLITE_MAX_CONCURRENT_READERS)
            .connect_lazy_with(options);

        Self(SQLiteStore::with_pool(pool, id))
    }

    /// Initialize the store by creating the tables if missing
    async fn init(&self) -> Result<(), sqlx::Error> {
        // Create a key-value store table for MMR accumulator state
        self.0.init().await?;
        // Create a table for encoded block headers
        let mut conn = self.0.acquire_connection().await?;
        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS block_headers (
                height INTEGER PRIMARY KEY,
                hash TEXT NOT NULL,
                header BLOB NOT NULL
            );"#,
        )
        .execute(conn.deref_mut())
        .await?;
        // Create a table for chain states
        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS chain_states (
                height INTEGER PRIMARY KEY,
                state BLOB NOT NULL
            );"#,
        )
        .execute(conn.deref_mut())
        .await?;
        // Add index on block hash column
        sqlx::query(
            r#"CREATE INDEX IF NOT EXISTS idx_block_headers_hash ON block_headers (hash);"#,
        )
        .execute(conn.deref_mut())
        .await?;
        Ok(())
    }

    /// Begin a new transaction.
    /// NOTE that this function does not check if there is already a transaction in progress.
    pub async fn begin(&self) -> Result<(), StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        SqliteTransactionManager::begin(&mut conn, None)
            .await
            .map_err(StoreError::SQLite)
    }

    /// Commit the current transaction.
    /// NOTE that this function does not check if there is a transaction in progress.
    pub async fn commit(&self) -> Result<(), StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        SqliteTransactionManager::commit(&mut conn)
            .await
            .map_err(StoreError::SQLite)
    }
}

#[async_trait]
impl ChainStateStore for AppStore {
    /// Add a new block header to the store
    async fn add_block_header(&self, height: u32, block_header: &Header) -> Result<(), StoreError> {
        let mut conn = self.0.acquire_connection().await?;

        let mut block_header_data = Vec::new();
        block_header
            .zcash_serialize(&mut block_header_data)
            .map_err(|e| StoreError::Custom(Box::new(e)))?;

        sqlx::query("INSERT INTO block_headers (height, hash, header) VALUES (?, ?, ?)")
            .bind(height)
            .bind(block_header.hash().to_string())
            .bind(block_header_data)
            .execute(conn.deref_mut())
            .await?;
        Ok(())
    }

    /// Get a range of block headers from the store
    async fn get_block_headers(
        &self,
        start_height: u32,
        num_blocks: u32,
    ) -> Result<Vec<Header>, StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        let rows = sqlx::query("SELECT header FROM block_headers WHERE height >= ? AND height < ?")
            .bind(start_height)
            .bind(start_height + num_blocks)
            .fetch_all(conn.deref_mut())
            .await?;
        rows.iter()
            .map(|row| {
                let header: Vec<u8> = row.get("header");
                Header::zcash_deserialize(&mut header.as_slice())
                    .map_err(|e| StoreError::Custom(Box::new(e)))
            })
            .collect()
    }

    /// Get the height of a block by its hash
    async fn get_block_height(&self, block_hash: &Hash) -> Result<u32, StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        let row = sqlx::query("SELECT height FROM block_headers WHERE hash = ?")
            .bind(block_hash.to_string())
            .fetch_optional(conn.deref_mut())
            .await?;
        row.map(|row| row.get("height")).ok_or(StoreError::GetError)
    }

    async fn get_chain_state(&self, height: u32) -> Result<ChainState, StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        let row = sqlx::query("SELECT state FROM chain_states WHERE height = ?")
            .bind(height)
            .fetch_optional(conn.deref_mut())
            .await?;
        let data: Vec<u8> = row.ok_or(StoreError::GetError)?.get("state");
        bincode::deserialize::<ChainState>(&data).map_err(|e| StoreError::Custom(Box::new(e)))
    }

    async fn get_latest_chain_state_height(&self) -> Result<u32, StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        let row = sqlx::query("SELECT height FROM chain_states ORDER BY height DESC LIMIT 1")
            .fetch_optional(conn.deref_mut())
            .await?;
        row.map(|row| row.get("height")).ok_or(StoreError::GetError)
    }

    async fn add_chain_state(
        &self,
        height: u32,
        chain_state: &ChainState,
    ) -> Result<(), StoreError> {
        let mut conn = self.0.acquire_connection().await?;
        let data = bincode::serialize(chain_state).map_err(|e| StoreError::Custom(Box::new(e)))?;
        sqlx::query("INSERT INTO chain_states (height, state) VALUES (?, ?)")
            .bind(height)
            .bind(data)
            .execute(conn.deref_mut())
            .await?;
        Ok(())
    }
}
