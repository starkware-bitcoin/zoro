use std::sync::Arc;

use accumulators::store::StoreError;
use async_trait::async_trait;
use hex::{FromHex, ToHex};
use raito_spv_verify::{proof::Target, ChainState};
use zebra_chain::{
    block::{Hash, Header},
    work::difficulty::{CompactDifficulty, ExpandedDifficulty, Work},
};

const BLOCKS_PER_EPOCH: u32 = 2016;
const POW_AVERAGING_WINDOW: usize = 17;
const MAX_TIMESTAMP_HISTORY: usize = 28;

#[async_trait]
pub trait ChainStateStore: Send + Sync {
    async fn add_block_header(&self, height: u32, block_header: &Header) -> Result<(), StoreError>;
    async fn get_block_headers(
        &self,
        start_height: u32,
        num_blocks: u32,
    ) -> Result<Vec<Header>, StoreError>;
    async fn get_block_height(&self, block_hash: &Hash) -> Result<u32, StoreError>;
    async fn add_chain_state(
        &self,
        height: u32,
        chain_state: &ChainState,
    ) -> Result<(), StoreError>;
    async fn get_chain_state(&self, height: u32) -> Result<ChainState, StoreError>;
}

pub struct ChainStateManager {
    current_state: ChainState,
    store: Arc<dyn ChainStateStore>,
}

impl ChainStateManager {
    pub async fn restore(
        store: Arc<dyn ChainStateStore>,
        height: u32,
    ) -> Result<Self, anyhow::Error> {
        let current_state = if height == 0 {
            Self::genesis_state()
        } else {
            store.get_chain_state(height - 1).await?
        };
        Ok(Self {
            current_state,
            store,
        })
    }

    pub async fn update(
        &mut self,
        block_height: u32,
        block_header: &Header,
    ) -> Result<(), anyhow::Error> {
        let new_state = if block_height == 0 {
            self.current_state.clone()
        } else {
            let block_time = block_header.time.timestamp() as u32;

            // Update recent timestamps with a capped history window.
            let mut prev_timestamps = self.current_state.prev_timestamps.clone();
            if prev_timestamps.len() == MAX_TIMESTAMP_HISTORY {
                prev_timestamps.remove(0);
            }
            prev_timestamps.push(block_time);

            // Convert compact difficulty (nBits) into an expanded 256‑bit target.
            let compact: CompactDifficulty = block_header.difficulty_threshold;
            let expanded = compact
                .to_expanded()
                .ok_or_else(|| anyhow::anyhow!("invalid difficulty threshold in header"))?;

            // Store the target in the chain state in big‑endian byte order.
            let target_hex: String = expanded.encode_hex();
            let current_target = Target::from_hex(&target_hex)?;

            // Accumulate total work using the Zcash work definition.
            let total_work = Self::compute_total_work(self.current_state.total_work, expanded);

            // Best block hash for the updated chain tip.
            let best_block_hash = block_header.hash();

            // Update PoW target history as a sliding window over recent targets.
            let mut pow_target_history = self.current_state.pow_target_history.clone();
            if pow_target_history.is_empty() {
                pow_target_history = (0..POW_AVERAGING_WINDOW)
                    .map(|_| current_target.clone())
                    .collect();
            } else if pow_target_history.len() == POW_AVERAGING_WINDOW {
                pow_target_history.remove(0);
            }
            pow_target_history.push(current_target.clone());

            // Epoch start time is the timestamp of the first block in each epoch.
            let epoch_start_time = if block_height % BLOCKS_PER_EPOCH == 0 {
                block_time
            } else {
                self.current_state.epoch_start_time
            };

            ChainState {
                block_height,
                total_work,
                best_block_hash,
                current_target,
                prev_timestamps,
                epoch_start_time,
                pow_target_history,
            }
        };

        self.store.add_chain_state(block_height, &new_state).await?;
        self.store
            .add_block_header(block_height, block_header)
            .await?;
        self.current_state = new_state;

        Ok(())
    }

    fn compute_total_work(prev_total_work: u128, expanded_target: ExpandedDifficulty) -> u128 {
        // Work::try_from implements the same 2^256 / (target + 1) formula as the Cairo code,
        // but stores the result as a u128.
        let work = Work::try_from(expanded_target)
            .expect("valid expanded difficulty must produce a finite Work value");
        prev_total_work
            .checked_add(work.as_u128())
            .expect("total work must not overflow u128")
    }

    pub fn genesis_state() -> ChainState {
        let current_target =
            Target::from_hex("0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
                .unwrap();
        let pow_target_history = (0..POW_AVERAGING_WINDOW)
            .map(|_| current_target.clone())
            .collect();

        ChainState {
            block_height: 0,
            total_work: 0x2000,
            best_block_hash: Hash::from_hex(
                "00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08",
            )
            .unwrap(),
            current_target,
            prev_timestamps: vec![1477641360],
            epoch_start_time: 1477641360,
            pow_target_history,
        }
    }
}
