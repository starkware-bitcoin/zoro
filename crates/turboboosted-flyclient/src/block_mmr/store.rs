//! Storage abstraction for the MMR tree

use async_trait::async_trait;
use sqlx::{pool::PoolConnection, sqlite::SqliteConnectOptions, Acquire, Pool, Sqlite, SqlitePool};
use std::collections::HashMap;
use std::ops::DerefMut;
use zcash_history::NodeData;

/// Trait for node storage backends (sync version for simple use cases)
pub trait NodeStore {
    fn get(&self, pos: u32) -> Option<NodeData>;
    fn set(&mut self, pos: u32, node: NodeData);
    fn len(&self) -> u32;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Async trait for node storage backends
#[async_trait]
pub trait AsyncNodeStore: Send + Sync {
    async fn get(&self, pos: u32) -> Option<NodeData>;
    async fn set(&self, pos: u32, node: NodeData) -> Result<(), sqlx::Error>;
    async fn set_many(&self, entries: HashMap<u32, NodeData>) -> Result<(), sqlx::Error>;
    async fn len(&self) -> u32;
}

/// In-memory storage (HashMap-backed)
#[derive(Default)]
pub struct MemoryStore {
    nodes: HashMap<u32, NodeData>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl NodeStore for MemoryStore {
    fn get(&self, pos: u32) -> Option<NodeData> {
        self.nodes.get(&pos).cloned()
    }

    fn set(&mut self, pos: u32, node: NodeData) {
        self.nodes.insert(pos, node);
    }

    fn len(&self) -> u32 {
        self.nodes.len() as u32
    }
}

/// SQLite-backed storage using sqlx (async)
#[derive(Debug)]
pub struct SqliteStore {
    pool: Pool<Sqlite>,
    cache: std::sync::RwLock<HashMap<u32, NodeData>>,
    len: std::sync::atomic::AtomicU32,
}

impl SqliteStore {
    pub async fn open(path: &str) -> Result<Self, sqlx::Error> {
        let options = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .synchronous(sqlx::sqlite::SqliteSynchronous::Normal);

        let pool = SqlitePool::connect_with(options).await?;
        Self::init_with_pool(pool).await
    }

    pub async fn open_in_memory() -> Result<Self, sqlx::Error> {
        let pool = SqlitePool::connect("sqlite::memory:").await?;
        Self::init_with_pool(pool).await
    }

    async fn init_with_pool(pool: Pool<Sqlite>) -> Result<Self, sqlx::Error> {
        let mut conn = pool.acquire().await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS nodes (
                pos INTEGER PRIMARY KEY,
                data BLOB NOT NULL
            )",
        )
        .execute(conn.deref_mut())
        .await?;

        let row: (i64,) = sqlx::query_as("SELECT COALESCE(MAX(pos) + 1, 0) FROM nodes")
            .fetch_one(conn.deref_mut())
            .await?;

        Ok(Self {
            pool,
            cache: std::sync::RwLock::new(HashMap::new()),
            len: std::sync::atomic::AtomicU32::new(row.0 as u32),
        })
    }

    async fn acquire(&self) -> Result<PoolConnection<Sqlite>, sqlx::Error> {
        self.pool.acquire().await
    }

    /// Flush cache to database
    pub async fn flush(&self) -> Result<(), sqlx::Error> {
        let entries: HashMap<u32, NodeData> = {
            let mut cache = self.cache.write().unwrap();
            std::mem::take(&mut *cache)
        };

        if entries.is_empty() {
            return Ok(());
        }

        self.set_many(entries).await
    }
}

#[async_trait]
impl AsyncNodeStore for SqliteStore {
    async fn get(&self, pos: u32) -> Option<NodeData> {
        // Check cache first
        if let Some(node) = self.cache.read().unwrap().get(&pos) {
            return Some(node.clone());
        }

        // Load from DB
        let mut conn = self.acquire().await.ok()?;
        let row: Option<(Vec<u8>,)> = sqlx::query_as("SELECT data FROM nodes WHERE pos = ?")
            .bind(pos as i64)
            .fetch_optional(conn.deref_mut())
            .await
            .ok()?;

        row.and_then(|(data,)| node_from_bytes(&data))
    }

    async fn set(&self, pos: u32, node: NodeData) -> Result<(), sqlx::Error> {
        // Update cache and len
        {
            let mut cache = self.cache.write().unwrap();
            cache.insert(pos, node.clone());
        }
        self.len
            .fetch_max(pos + 1, std::sync::atomic::Ordering::SeqCst);

        // Write to DB
        let mut conn = self.acquire().await?;
        let data = node_to_bytes(&node);
        sqlx::query("INSERT OR REPLACE INTO nodes (pos, data) VALUES (?, ?)")
            .bind(pos as i64)
            .bind(data)
            .execute(conn.deref_mut())
            .await?;

        Ok(())
    }

    async fn set_many(&self, entries: HashMap<u32, NodeData>) -> Result<(), sqlx::Error> {
        if entries.is_empty() {
            return Ok(());
        }

        let mut conn = self.acquire().await?;
        let mut tx = conn.begin().await?;

        // Batch insert using multi-value INSERT
        const BATCH_SIZE: usize = 100;
        let entries_vec: Vec<_> = entries.iter().collect();

        for chunk in entries_vec.chunks(BATCH_SIZE) {
            let placeholders: String = chunk
                .iter()
                .map(|_| "(?, ?)")
                .collect::<Vec<_>>()
                .join(", ");
            let query = format!(
                "INSERT OR REPLACE INTO nodes (pos, data) VALUES {}",
                placeholders
            );

            let mut q = sqlx::query(&query);
            for (pos, node) in chunk {
                q = q.bind(**pos as i64).bind(node_to_bytes(node));
            }
            q.execute(&mut *tx).await?;
        }

        tx.commit().await?;

        // Update len
        if let Some(max_pos) = entries.keys().max() {
            self.len
                .fetch_max(*max_pos + 1, std::sync::atomic::Ordering::SeqCst);
        }

        Ok(())
    }

    async fn len(&self) -> u32 {
        self.len.load(std::sync::atomic::Ordering::SeqCst)
    }
}

// Sync NodeStore implementation using tokio's block_in_place
impl NodeStore for SqliteStore {
    fn get(&self, pos: u32) -> Option<NodeData> {
        // Check cache first (no async needed)
        if let Some(node) = self.cache.read().unwrap().get(&pos) {
            return Some(node.clone());
        }

        // For DB access, we need async
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(AsyncNodeStore::get(self, pos))
        })
    }

    fn set(&mut self, pos: u32, node: NodeData) {
        // Just update cache (write-back), flush() persists
        self.cache.write().unwrap().insert(pos, node);
        self.len
            .fetch_max(pos + 1, std::sync::atomic::Ordering::SeqCst);
    }

    fn len(&self) -> u32 {
        self.len.load(std::sync::atomic::Ordering::SeqCst)
    }
}

// Serialization helpers

fn node_to_bytes(n: &NodeData) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&n.consensus_branch_id.to_le_bytes());
    n.write(&mut buf).expect("write to vec");
    buf
}

fn node_from_bytes(b: &[u8]) -> Option<NodeData> {
    if b.len() < 4 {
        return None;
    }
    let branch_id = u32::from_le_bytes(b[0..4].try_into().ok()?);
    NodeData::read(branch_id, &mut &b[4..]).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block_mmr::branch_id;
    use primitive_types::U256;

    fn test_node(i: u32) -> NodeData {
        NodeData {
            consensus_branch_id: branch_id::HEARTWOOD,
            subtree_commitment: [(i + 1) as u8; 32],
            start_time: 1000 + i,
            end_time: 1000 + i,
            start_target: 0x1d00ffff,
            end_target: 0x1d00ffff,
            start_sapling_root: [0u8; 32],
            end_sapling_root: [0u8; 32],
            subtree_total_work: U256::from(100),
            start_height: (903_000 + i) as u64,
            end_height: (903_000 + i) as u64,
            sapling_tx: i as u64,
        }
    }

    #[test]
    fn test_memory_store() {
        let mut store = MemoryStore::new();
        assert!(store.is_empty());

        store.set(0, test_node(0));
        store.set(1, test_node(1));

        assert_eq!(store.len(), 2);
        assert_eq!(store.get(0).unwrap().start_height, 903_000);
        assert_eq!(store.get(1).unwrap().start_height, 903_001);
        assert!(store.get(2).is_none());
    }

    #[tokio::test]
    async fn test_sqlite_store_async() {
        let store = SqliteStore::open_in_memory().await.unwrap();
        assert!(AsyncNodeStore::len(&store).await == 0);

        AsyncNodeStore::set(&store, 0, test_node(0)).await.unwrap();
        AsyncNodeStore::set(&store, 1, test_node(1)).await.unwrap();

        assert_eq!(AsyncNodeStore::len(&store).await, 2);
        assert_eq!(
            AsyncNodeStore::get(&store, 0).await.unwrap().start_height,
            903_000
        );
        assert_eq!(
            AsyncNodeStore::get(&store, 1).await.unwrap().start_height,
            903_001
        );
        assert!(AsyncNodeStore::get(&store, 2).await.is_none());
    }

    #[test]
    fn test_store_trait_polymorphism() {
        fn count_nodes(store: &dyn NodeStore) -> u32 {
            store.len()
        }

        let mut mem = MemoryStore::new();
        mem.set(0, test_node(0));

        assert_eq!(count_nodes(&mem), 1);
    }
}
