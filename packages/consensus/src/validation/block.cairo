//! Block validation helpers.

use utils::double_sha256::double_sha256_word_array;
use utils::hash::Digest;
use utils::merkle_tree::merkle_root;
use utils::word_array::WordArrayTrait;
use crate::codec::Encode;
use crate::types::block::{Block, TransactionData};
use crate::types::chain_state::ChainState;
use crate::types::transaction::{OutPoint, Transaction};
use crate::types::utxo_set::{UtxoSet, UtxoSetTrait};
use crate::validation::coinbase::validate_coinbase;
use crate::validation::header::validate_header;
use crate::validation::script::validate_scripts;
use crate::validation::timestamp::compute_median_time_past;
use crate::validation::transaction::validate_transaction;

const MAX_BLOCK_BYTES: usize = 2_000_000;

/// Validates block given the [ChainState], [Block] and the [UtxoSet].
/// Returns the new chain state.
pub fn validate_block(
    state: ChainState, block: Block, ref utxo_set: UtxoSet,
) -> Result<ChainState, ByteArray> {
    // MTP of the previous block
    let median_time_past = compute_median_time_past(state.prev_timestamps);

    // Validate the block data
    let txid_root = match block.data {
        TransactionData::MerkleRoot(root) => root,
        TransactionData::Transactions(txs) => {
            // Height of the current block
            let block_height = state.block_height + 1;

            let (total_fees, txid_root) = compute_and_validate_tx_data(
                txs, block_height, block.header.time, median_time_past, ref utxo_set,
            )?;

            validate_coinbase(txs[0], total_fees, block_height)?;
            validate_scripts(@block.header, txs.slice(1, txs.len() - 1))?;
            txid_root
        },
    };

    validate_header(state, block, txid_root, median_time_past)
}

/// Validates block weight.
/// Zcash blocks are limited to 2 MB of serialized data.
pub fn validate_block_weight(bytes: usize) -> Result<(), ByteArray> {
    if bytes > MAX_BLOCK_BYTES {
        return Result::Err(
            format!(
                "[validate_weight] block size {bytes} exceeds the limit {MAX_BLOCK_BYTES} bytes",
            ),
        );
    }

    Result::Ok(())
}

/// Validates transactions and returns:
///  - Total fee
///  - TXID merkle root
pub fn compute_and_validate_tx_data(
    txs: Span<Transaction>,
    block_height: u32,
    block_time: u32,
    median_time_past: u32,
    ref utxo_set: UtxoSet,
) -> Result<(u64, Digest), ByteArray> {
    let mut txids: Array<Digest> = array![];
    let mut total_fee = 0;
    let mut total_size_bytes: usize = 0;
    let mut inner_result = Result::Ok(());
    let mut is_coinbase = true;

    for tx in txs {
        let tx_words = tx.encode();
        let tx_byte_len = tx_words.byte_len();

        let txid = double_sha256_word_array(tx_words);

        total_size_bytes += tx_byte_len;

        txids.append(txid);

        if (is_coinbase) {
            let mut vout = 0;
            for output in *tx.outputs {
                let outpoint = OutPoint {
                    txid, vout, data: *output, block_height, median_time_past, is_coinbase: true,
                };
                inner_result = utxo_set.add(outpoint);
                if inner_result.is_err() {
                    break;
                }
                vout += 1;
            }
            is_coinbase = false;
        } else {
            let fee =
                match validate_transaction(
                    tx, block_height, block_time, median_time_past, txid, ref utxo_set,
                ) {
                Result::Ok(fee) => fee,
                Result::Err(err) => {
                    inner_result = Result::Err(err);
                    break;
                },
            };
            total_fee += fee;
        }
    }

    inner_result?;
    validate_block_weight(total_size_bytes)?;

    Result::Ok((total_fee, merkle_root(txids.span())))
}
