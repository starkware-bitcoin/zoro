//! Block header validation.

use consensus::params::{LEGACY_EPOCH_INTERVAL, POW_AVERAGING_WINDOW, POW_LIMIT};
use consensus::types::block::{Block, BlockHash, TransactionData};
use consensus::types::chain_state::{ChainState, ensure_pow_history};
use consensus::validation::difficulty::{
    adjust_difficulty, has_full_pow_window, next_pow_targets, validate_bits,
};
use consensus::validation::equihash::check_equihash_solution;
use consensus::validation::timestamp::{
    compute_median_time_past, median_time_past_at_offset, next_prev_timestamps, validate_timestamp,
};
use consensus::validation::work::{compute_total_work, validate_proof_of_work};
use utils::hash::Digest;

/// Validates block header given the [Block] and the initial [ChainState].
/// Assumes that the block data is a Merkle root rather than a list of transactions.
pub fn validate_block_header(state: ChainState, block: Block) -> Result<ChainState, ByteArray> {
    let txid_root = match block.data {
        TransactionData::MerkleRoot(root) => root,
        TransactionData::Transactions(_) => panic!("Expected Merkle root"),
    };

    let median_time_past = compute_median_time_past(state.prev_timestamps);
    validate_header(state, block, txid_root, median_time_past)
}

/// Validates block header given the [Block], initial [ChainState], and auxiliary data (to avoid
/// recomputing it):
/// - Transaction (Merkle) root
/// - MTP (median time past) of the previous block
///
/// Returns the new chain state.
pub fn validate_header(
    state: ChainState, block: Block, txid_root: Digest, prev_mtp: u32,
) -> Result<ChainState, ByteArray> {
    let block_height = state.block_height + 1;

    let prev_timestamps = next_prev_timestamps(state.prev_timestamps, block.header.time);

    validate_timestamp(prev_mtp, block.header.time)?;

    let pow_history = ensure_pow_history(state.pow_target_history, state.current_target);
    let mut current_target = state.current_target;
    if has_full_pow_window(pow_history) {
        if let Option::Some(window_start_mtp) =
            median_time_past_at_offset(state.prev_timestamps, POW_AVERAGING_WINDOW) {
            current_target =
                adjust_difficulty(pow_history, block_height, prev_mtp, window_start_mtp);
        } else {
            current_target = POW_LIMIT;
        }
    } else {
        current_target = POW_LIMIT;
    }
    let total_work = compute_total_work(state.total_work, current_target);
    let best_block_hash = block.header.hash(state.best_block_hash, txid_root);
    let pow_target_history = next_pow_targets(pow_history, current_target);

    check_equihash_solution(@block.header, state.best_block_hash, txid_root)?;
    validate_proof_of_work(current_target, best_block_hash)?;
    validate_bits(current_target, block.header.bits)?;

    let mut epoch_start_time = state.epoch_start_time;
    if block_height % LEGACY_EPOCH_INTERVAL == 0 {
        epoch_start_time = block.header.time;
    }

    Ok(
        ChainState {
            block_height,
            total_work,
            best_block_hash,
            current_target,
            prev_timestamps,
            pow_target_history,
            epoch_start_time,
        },
    )
}
