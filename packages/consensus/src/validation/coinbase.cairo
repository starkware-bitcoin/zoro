//! Coinbase validation helpers.
//!
//! https://learnmeabitcoin.com/technical/mining/coinbase-transaction/

use utils::pow32;
use crate::types::transaction::{Transaction, TxIn};

const ZCASH_BLOCK_SUBSIDY: u64 = 1_250_000_000; // 12.5 ZEC in zatoshis.
const ZCASH_HALVING_INTERVAL: u32 = 1_046_400;
const COINBASE_SCRIPT_ENFORCEMENT_HEIGHT: u32 = 0;

/// Validates coinbase transaction.
pub fn validate_coinbase(
    tx: @Transaction, total_fees: u64, block_height: u32,
) -> Result<(), ByteArray> {
    // Ensure there is exactly one coinbase input
    if (*tx.inputs).len() != 1 {
        return Result::Err("Input count must be 1");
    }

    validate_coinbase_input(tx.inputs[0], block_height)?;

    // Validate the outputs' amounts
    // Sum up the total amount of all outputs of the coinbase transaction
    let mut total_output_amount = 0;
    for output in *tx.outputs {
        total_output_amount += *output.value;
    }

    // Ensure the total output amount is at most the block reward + TX fees
    let block_reward = compute_block_reward(block_height);
    if total_output_amount > total_fees + block_reward {
        return Result::Err(
            format!(
                "coinbase outputs exceed subsidy: outputs {}, reward {}, fees {}",
                total_output_amount,
                block_reward,
                total_fees,
            ),
        );
    }

    Result::Ok(())
}

/// Validates the first and only coinbase input.
fn validate_coinbase_input(input: @TxIn, block_height: u32) -> Result<(), ByteArray> {
    // Ensure the input's vout is 0xFFFFFFFF
    if *input.previous_output.vout != 0xFFFFFFFF {
        return Result::Err("Previous vout must be 0xFFFFFFFF");
    }

    // Ensure the input's TXID is zero
    if *input.previous_output.txid != Default::default() {
        return Result::Err("Previous txid must be zero");
    }

    // validate BIP-34 sig script
    if block_height >= COINBASE_SCRIPT_ENFORCEMENT_HEIGHT {
        validate_coinbase_sig_script(*input.script, block_height)?;
    }

    Result::Ok(())
}

/// Validates coinbase sig script (BIP-34).
fn validate_coinbase_sig_script(script: @ByteArray, block_height: u32) -> Result<(), ByteArray> {
    let script_len = script.len();

    // Ensure byte length greater than 2 and less 100
    if script_len < 2 || script_len > 100 {
        return Result::Err("Bad sig script length");
    }

    // Ensure script starts with the current block height
    //
    // First byte is number of bytes in the number (will be 0x03 on mainnet for the next
    // 150 or so years with 223-1 blocks), following bytes are little-endian representation
    // of the number
    if script[0] != 3 {
        return Result::Err("Invalid number of bytes");
    }

    let result = script[1].into() + script[2].into() * 256_u32 + script[3].into() * 65536_u32;
    if result != block_height {
        return Result::Err("Wrong block height");
    }

    Result::Ok(())
}

/// Returns BTC reward in SATS.
fn compute_block_reward(block_height: u32) -> u64 {
    let halvings = block_height / ZCASH_HALVING_INTERVAL;
    println!("halvings: {}", halvings);
    ZCASH_BLOCK_SUBSIDY / pow32(halvings)
}

#[cfg(test)]
mod tests {
    use utils::hex::{from_hex, hex_to_hash_rev};
    use crate::types::transaction::{OutPoint, Transaction, TxIn, TxOut};
    use super::{
        ZCASH_HALVING_INTERVAL, compute_block_reward, validate_coinbase, validate_coinbase_input,
        validate_coinbase_sig_script,
    };

    fn legacy_tx(inputs: Span<TxIn>, outputs: Span<TxOut>) -> Transaction {
        Transaction {
            version: 4,
            overwintered: Option::Some(true),
            version_group_id: Option::Some(0),
            consensus_branch_id: Option::Some(0),
            inputs,
            outputs,
            lock_time: 0,
            expiry_height: Option::Some(0),
            value_balance_sapling: Option::None,
            value_balance_orchard: Option::None,
            sapling_bundle: Option::None,
            orchard_bundle: Option::None,
            sprout_bundle: Option::None,
            is_segwit: false,
        }
    }

    #[test]
    fn test_validate_coinbase_with_more_than_one_input() {
        let tx = legacy_tx(
            array![dummy_coinbase_input(), dummy_coinbase_input()].span(),
            array![dummy_output(1_250_000_000_u64)].span(),
        );
        validate_coinbase(@tx, 0, 0).unwrap_err();
    }

    #[test]
    fn test_validate_coinbase_with_wrong_vout() {
        let mut input = dummy_coinbase_input();
        input.previous_output.vout = 1;
        validate_coinbase_input(@input, 0).unwrap_err();
    }

    #[test]
    fn test_validate_coinbase_with_txid_not_zero() {
        let mut input = dummy_coinbase_input();
        input
            .previous_output
            .txid =
                hex_to_hash_rev("0100000000000000000000000000000000000000000000000000000000000000");
        validate_coinbase_input(@input, 0).unwrap_err();
    }

    #[test]
    fn test_validate_coinbase_outputs_amount() {
        let tx = legacy_tx(
            array![dummy_coinbase_input()].span(), array![dummy_output(2_000_000_000_u64)].span(),
        );
        validate_coinbase(@tx, 0, 0).unwrap_err();
    }

    #[test]
    fn test_validate_coinbase_accepts_valid_tx() {
        let tx = legacy_tx(
            array![dummy_coinbase_input()].span(), array![dummy_output(1_250_000_000_u64)].span(),
        );
        validate_coinbase(@tx, 0, 0).unwrap();
    }

    #[test]
    fn test_validate_coinbase_sig_script_length_checks() {
        let script = from_hex("");
        validate_coinbase_sig_script(@script, 1).unwrap_err();

        let long_script = from_hex(
            "4104d46c4968bde02899d2aa0963367c7a6ce34eec332b32e42e5f3407e052d64ac625da6f0718e7b302140434bd725706957c092db53805b821a85b23a7ac61725bac4104d46c4968bde02899d2aa0963367c7a6ce34eec332b32e42e5f3407e052d64ac625da6f0718e7b302140434bd725706957c092db53805b821a85b23a7ac61725bac",
        );
        validate_coinbase_sig_script(@long_script, 1).unwrap_err();
    }

    #[test]
    fn test_validate_coinbase_sig_script_height_encoding() {
        let wrong_height = from_hex("03aa68060004c3");
        validate_coinbase_sig_script(@wrong_height, 1).unwrap_err();

        let correct = from_hex("03010000");
        validate_coinbase_sig_script(@correct, 1).unwrap();
    }

    #[test]
    fn test_compute_block_reward_halving() {
        assert_eq!(compute_block_reward(0), 1_250_000_000);
        assert_eq!(compute_block_reward(ZCASH_HALVING_INTERVAL), 625_000_000);
        assert_eq!(compute_block_reward(ZCASH_HALVING_INTERVAL * 2), 312_500_000);
    }

    fn dummy_coinbase_input() -> TxIn {
        TxIn {
            script: @from_hex("03000000"),
            sequence: 0xffffffff,
            previous_output: OutPoint {
                txid: 0_u256.into(),
                vout: 0xffffffff,
                data: TxOut { value: 0, pk_script: @from_hex(""), cached: false },
                block_height: 0,
                median_time_past: 0,
                is_coinbase: false,
            },
            witness: array![].span(),
        }
    }

    fn dummy_output(value: u64) -> TxOut {
        TxOut { value, pk_script: @from_hex("4104d46c4968bde0"), cached: false }
    }
}
