//! Block header validation.

use consensus::params::{DIFF1_TARGET, LEGACY_EPOCH_INTERVAL, POW_AVERAGING_WINDOW};
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
///
/// # Arguments
/// * `state` - Current chain state
/// * `block` - Block to validate
/// * `sorted_indices_hint` - Prover hint: Equihash indices sorted ascending (for O(n) uniqueness
/// check)
pub fn validate_block_header(
    state: ChainState, block: Block, sorted_indices_hint: Span<u32>,
) -> Result<ChainState, ByteArray> {
    let txid_root = match block.data {
        TransactionData::MerkleRoot(root) => root,
    };

    let median_time_past = compute_median_time_past(state.prev_timestamps);
    validate_header(state, block, txid_root, median_time_past, sorted_indices_hint)
}

/// Validates block header given the [Block], initial [ChainState], and auxiliary data (to avoid
/// recomputing it):
/// - Transaction (Merkle) root
/// - MTP (median time past) of the previous block
/// - Sorted indices hint for Equihash uniqueness verification
///
/// Returns the new chain state.
pub fn validate_header(
    state: ChainState,
    block: Block,
    txid_root: Digest,
    prev_mtp: u32,
    sorted_indices_hint: Span<u32>,
) -> Result<ChainState, ByteArray> {
    let block_height = state.block_height + 1;

    let prev_timestamps = next_prev_timestamps(state.prev_timestamps, block.header.time);

    validate_timestamp(prev_mtp, block.header.time)?;

    let pow_history = ensure_pow_history(state.pow_target_history, state.current_target);

    // Zcash difficulty adjustment (zcashd GetNextWorkRequired in pow.cpp):
    // For the first nPoWAveragingWindow blocks, return powLimit.GetCompact() expanded back.
    // This equals DIFF1_TARGET (the compact form of POW_LIMIT expanded to 256-bit).

    let current_target = if block_height < POW_AVERAGING_WINDOW {
        // Early blocks: use genesis difficulty (DIFF1_TARGET)
        // This matches zcashd: return UintToArith256(params.powLimit).GetCompact()
        // and Zebra: network.target_difficulty_limit() which is PoWLimit.to_compact().to_expanded()
        DIFF1_TARGET
    } else if has_full_pow_window(pow_history) {
        // Normal case: run DigiShield-v3 difficulty adjustment
        if let Option::Some(window_start_mtp) =
            median_time_past_at_offset(state.prev_timestamps, POW_AVERAGING_WINDOW) {
            adjust_difficulty(pow_history, block_height, prev_mtp, window_start_mtp)
        } else {
            // Fallback if MTP calculation fails (shouldn't happen with proper history)
            // Zebra returns target_difficulty_limit() which is PoWLimit.to_compact().to_expanded()
            DIFF1_TARGET
        }
    } else {
        // Not enough pow_history yet - use target_difficulty_limit
        // Zebra: mean_target_difficulty() returns target_difficulty_limit() when < 17 thresholds
        DIFF1_TARGET
    };
    let total_work = compute_total_work(state.total_work, current_target);
    let best_block_hash = block.header.hash(state.best_block_hash, txid_root);
    let pow_target_history = next_pow_targets(pow_history, current_target);

    check_equihash_solution(block.header, state.best_block_hash, txid_root, sorted_indices_hint)?;
    validate_proof_of_work(current_target, best_block_hash)?;
    validate_bits(current_target, block.header.bits, block_height)?;

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
