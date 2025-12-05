//! Storage abstraction for the MMR tree

use rusqlite::{params, Connection};
use std::collections::HashMap;
use zcash_history::NodeData;

/// Trait for node storage backends
pub trait NodeStore {
    fn get(&self, pos: u32) -> Option<NodeData>;
    fn set(&mut self, pos: u32, node: NodeData);
    fn len(&self) -> u32;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
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

/// SQLite-backed storage (loads on demand)
pub struct SqliteStore {
    conn: Connection,
    cache: HashMap<u32, NodeData>, // Small LRU cache for hot nodes
    len: u32,
}

impl SqliteStore {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        Self::init_with_conn(conn)
    }

    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::init_with_conn(conn)
    }

    fn init_with_conn(conn: Connection) -> rusqlite::Result<Self> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS nodes (
                pos INTEGER PRIMARY KEY,
                data BLOB NOT NULL
            );",
        )?;

        let len: u32 =
            conn.query_row("SELECT COALESCE(MAX(pos) + 1, 0) FROM nodes", [], |row| {
                row.get(0)
            })?;

        Ok(Self {
            conn,
            cache: HashMap::new(),
            len,
        })
    }

    fn load_from_db(&self, pos: u32) -> Option<NodeData> {
        let mut stmt = self
            .conn
            .prepare("SELECT data FROM nodes WHERE pos = ?1")
            .ok()?;
        let data: Vec<u8> = stmt.query_row(params![pos], |row| row.get(0)).ok()?;
        node_from_bytes(&data)
    }

    fn save_to_db(&self, pos: u32, node: &NodeData) -> rusqlite::Result<()> {
        let data = node_to_bytes(node);
        self.conn.execute(
            "INSERT OR REPLACE INTO nodes (pos, data) VALUES (?1, ?2)",
            params![pos, data],
        )?;
        Ok(())
    }

    /// Flush cache to database
    pub fn flush(&mut self) -> rusqlite::Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        for (pos, node) in &self.cache {
            self.save_to_db(*pos, node)?;
        }
        tx.commit()?;
        self.cache.clear();
        Ok(())
    }
}

impl NodeStore for SqliteStore {
    fn get(&self, pos: u32) -> Option<NodeData> {
        // Check cache first
        if let Some(node) = self.cache.get(&pos) {
            return Some(node.clone());
        }
        // Load from DB
        self.load_from_db(pos)
    }

    fn set(&mut self, pos: u32, node: NodeData) {
        // Write-through: save to DB immediately
        let _ = self.save_to_db(pos, &node);
        self.cache.insert(pos, node);
        if pos >= self.len {
            self.len = pos + 1;
        }
    }

    fn len(&self) -> u32 {
        self.len
    }
}

impl Drop for SqliteStore {
    fn drop(&mut self) {
        let _ = self.flush();
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

    #[test]
    fn test_sqlite_store() {
        let mut store = SqliteStore::open_in_memory().unwrap();
        assert!(store.is_empty());

        store.set(0, test_node(0));
        store.set(1, test_node(1));

        assert_eq!(store.len(), 2);

        // Clear cache to force DB read
        store.cache.clear();

        assert_eq!(store.get(0).unwrap().start_height, 903_000);
        assert_eq!(store.get(1).unwrap().start_height, 903_001);
        assert!(store.get(2).is_none());
    }

    #[test]
    fn test_store_trait_polymorphism() {
        fn count_nodes(store: &dyn NodeStore) -> u32 {
            store.len()
        }

        let mut mem = MemoryStore::new();
        mem.set(0, test_node(0));

        let mut sql = SqliteStore::open_in_memory().unwrap();
        sql.set(0, test_node(0));

        assert_eq!(count_nodes(&mem), 1);
        assert_eq!(count_nodes(&sql), 1);
    }
}
