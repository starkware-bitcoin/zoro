//! Zcash transaction and its components.
//!
//! Types are extended with extra information required for validation.
//! The data is expected to be prepared in advance and passed as program arguments.

use core::fmt::{Display, Error, Formatter};
use core::hash::{Hash, HashStateExTrait, HashStateTrait};
use core::integer::i64;
use core::poseidon::PoseidonTrait;
use utils::bytearray::{ByteArraySnapHash, ByteArraySnapSerde};
use utils::hash::Digest;

/// Represents a Zcash transaction (Sapling/Orchard aware).
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct Transaction {
    /// The version of the transaction.
    pub version: u32,
    /// Indicates whether the Overwinter serialization rules apply. Optional for compatibility
    /// with legacy Bitcoin fixtures; defaults to `false` if omitted.
    pub overwintered: Option<bool>,
    /// Version group identifier (e.g. 0x892F2085 for Sapling). Optional to keep backward
    /// compatibility with the current Bitcoin-based fixtures; once the JSON inputs are regenerated
    /// this will always be `Some`.
    pub version_group_id: Option<u32>,
    /// Consensus branch id used by ZIP 243/244 (only meaningful for ZIP225+ transactions).
    pub consensus_branch_id: Option<u32>,
    /// Transparent inputs.
    pub inputs: Span<TxIn>,
    /// Transparent outputs.
    pub outputs: Span<TxOut>,
    /// Block height / time after which this transaction can be mined.
    /// Locktime feature is enabled if at least one input has sequence <= 0xfffffffe.
    pub lock_time: u32,
    /// The last height at which this transaction is valid.
    pub expiry_height: Option<u32>,
    /// Net value entering the Sapling pool (ZIP 209). Positive values mean shielded inputs exceed
    /// outputs, negative values mean the transaction creates shielded value.
    pub value_balance_sapling: Option<i64>,
    /// Net value entering the Orchard pool.
    pub value_balance_orchard: Option<i64>,
    /// Optional Sapling bundle if the transaction contains shielded spends/outputs.
    pub sapling_bundle: Option<SaplingBundle>,
    /// Optional Orchard bundle for NU5 transactions.
    pub orchard_bundle: Option<OrchardBundle>,
    /// Optional Sprout (JoinSplit) bundle for legacy transactions.
    pub sprout_bundle: Option<SproutBundle>,
    /// Placeholder for SegWit marker/flag. Zcash transactions never carry witness data, but the
    /// existing validation and data pipelines still expect this flag. It MUST be `false` for any
    /// Zcash block.
    pub is_segwit: bool,
}

/// Zcash transparent transaction input.
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct TxIn {
    /// The signature script which satisfies the conditions placed in the txo pubkey script
    /// or coinbase script that contains block height (since 227,836) and miner nonce (optional).
    pub script: @ByteArray,
    /// This field enables absolute or relative locktime feature, basically how much time or how
    /// many blocks must pass (since genesis or since the referenced output was mined) before this
    /// transaction can be mined.
    pub sequence: u32,
    /// The reference to the previous output that is being spent by this input.
    pub previous_output: OutPoint,
    /// Placeholder for SegWit-style witness data. Zcash transactions do not carry witness stacks,
    /// but we keep this field temporarily so that legacy validation code continues to compile
    /// while we migrate the rest of the pipeline. It MUST be empty for valid Zcash blocks.
    pub witness: Span<ByteArray>,
}

/// A reference to an unspent transaction output (UTXO).
///
/// NOTE that `data` and `block_height` meta fields are not serialized with the rest of
/// the transaction and hence are not constrained with the transaction hash.
///
/// There are four possible cases:
///   1. Coinbase input that does not spend any outputs (zero txid)
///   2. Input that spends an output created within the same block (cached)
///   3. Input that spends a coinbase output
///   4. Input that spends an output from a past block
///
/// For (1) we don't need to add extra constraints, because meta fields are not used.
/// For (2) we need to check that the referenced output is indeed cached:
///     * Calculate cache key by hashing (txid, vout, data)
///     * Check if the key is present in the cache
///     * Remove item from the cache
/// For (3) we need to check that the referenced output is in the utreexo accumulator:
///     * Calculate utreexo leaf hash from (txid, vout, data, block_height)
///     * Verify inclusion proof (either individual or batched) against the roots
///     * Delete the leaf from the accumulator
/// For (4) we need to additionally check if the coinbase output is older than 100 blocks
///
/// IMPORTANT:
///     * Utreexo proofs can be verified at any point of block validation because accumulator
///       is not changing until the end of the block;
///     * Cache lookups MUST be done in a sequential order, i.e. transactions are validated
///       one by one, first inputs then outputs. Output validation might put something to the
///       cache while input validation might remove an item, thus it's important to maintain
///       the order.
#[derive(Drop, Copy, Debug, PartialEq, Serde, Hash)]
pub struct OutPoint {
    /// The hash of the referenced transaction.
    pub txid: Digest,
    /// The index of the specific output in the transaction.
    pub vout: u32,
    /// Referenced output data (meta field).
    /// Must be set to default for coinbase inputs.
    pub data: TxOut,
    /// The height of the block that contains this output (meta field).
    /// Used to validate coinbase tx spending (not sooner than 100 blocks) and relative timelocks
    /// (it has been more than X blocks since the transaction containing this output was mined).
    pub block_height: u32,
    /// The median time past of the block that contains this output (meta field).
    /// This is the median timestamp of the previous 11 blocks.
    /// Used to validate relative timelocks based on time (BIP 68 and BIP 112).
    /// It ensures that the transaction containing this output has been mined for more than X
    /// seconds.
    pub median_time_past: u32,
    /// Determines if the outpoint is a coinbase transaction.
    pub is_coinbase: bool,
}


/// Output of a transaction.
/// https://learnmeabitcoin.com/technical/transaction/output/
///
/// NOTE: that `cached` meta field is not serialized with the rest of the output data,
/// so it's not constrained by the transaction hash when UTXO hash is computed.
///
/// Upon processing (validating) an output one of three actions must be taken:
///     - Add output with some extra info (see [OutPoint]) to the Utreexo accumulator
///     - Add output to the cache in case it is going to be spent in the same block
///     - Do nothing in case of a provably unspendable output
///
/// Read more: https://en.bitcoin.it/wiki/Script#Provably_Unspendable/Prunable_Outputs
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct TxOut {
    /// The value of the output in zatoshis (1e-8 ZEC).
    pub value: u64,
    /// The spending script (aka locking code) for this output.
    pub pk_script: @ByteArray,
    /// Meta flag indicating that this output will be spent within the current block(s).
    /// This output won't be added to the utreexo accumulator.
    /// Note that coinbase outputs cannot be spent sooner than 100 blocks after inclusion.
    pub cached: bool,
}

/// Sapling shielded bundle data. Mirrors the layout described in
/// [`SaplingBundle`](https://raw.githubusercontent.com/ZcashFoundation/zcashd/refs/heads/master/src/primitives/transaction.cpp).
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct SaplingBundle {
    /// Shared anchor for all shielded spends in this bundle.
    pub anchor: Digest,
    pub value_balance: i64,
    pub spends: Span<SaplingSpendDescription>,
    pub outputs: Span<SaplingOutputDescription>,
    pub binding_sig: @ByteArray,
}

#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct SaplingSpendDescription {
    pub cv: Digest,
    pub nullifier: Digest,
    pub rk: Digest,
    pub zkproof: @ByteArray,
    pub spend_auth_sig: @ByteArray,
}

#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct SaplingOutputDescription {
    pub cv: Digest,
    pub cmu: Digest,
    pub ephemeral_key: Digest,
    pub enc_ciphertext: @ByteArray,
    pub out_ciphertext: @ByteArray,
    pub zkproof: @ByteArray,
}

/// Orchard bundle bytes plus minimal metadata (see
/// [`OrchardBundle`](https://raw.githubusercontent.com/ZcashFoundation/zcashd/refs/heads/master/src/primitives/orchard.h)).
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct OrchardBundle {
    pub value_balance: i64,
    /// Canonical serialized bytes as produced by the Orchard Rust crate.
    pub raw_bytes: @ByteArray,
}

/// Sprout joinsplit bundle (raw bytes). The host environment is expected to provide fully
/// serialized joinsplits along with the associated proof data.
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct SproutBundle {
    pub joinsplits: Span<SproutJoinSplit>,
    pub pub_key: @ByteArray,
    pub signature: @ByteArray,
}

/// Sprout JoinSplit description following the layout of `JSDescription`.
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct SproutJoinSplit {
    pub vpub_old: u64,
    pub vpub_new: u64,
    pub anchor: Digest,
    /// Two nullifiers describing the notes being spent.
    pub nullifiers: Span<Digest>,
    /// Two commitments for the newly created notes.
    pub commitments: Span<Digest>,
    pub ephemeral_key: Digest,
    pub random_seed: Digest,
    /// Two MACs proving spend authorization.
    pub macs: Span<Digest>,
    /// Serialized Groth16/BCTV14 proof bytes depending on the branch id.
    pub proof: @ByteArray,
    /// Two note ciphertexts, each encoded as a 601-byte blob in `zcashd`.
    pub ciphertexts: Span<ByteArray>,
}

/// Custom implementation of the `Hash` trait for `TxOut`, excluding `cached` field.
impl TxOutHash<S, +HashStateTrait<S>, +Drop<S>> of Hash<TxOut, S> {
    fn update_state(state: S, value: TxOut) -> S {
        let state = state.update(value.value.into());
        let state = state.update_with(value.pk_script);
        state
    }
}

/// `Outpoint` Poseidon hash implementation.
#[generate_trait]
pub impl OutPointHashImpl of OutPointHashTrait {
    fn hash(self: @OutPoint) -> felt252 {
        PoseidonTrait::new().update_with(*self).finalize()
    }
}

/// `Default` trait implementation for `TxOut`.
impl TxOutDefault of Default<TxOut> {
    fn default() -> TxOut {
        TxOut { value: 0, pk_script: @"", cached: false }
    }
}

/// `Display` trait implementation for `Transaction`.
impl TransactionDisplay of Display<Transaction> {
    fn fmt(self: @Transaction, ref f: Formatter) -> Result<(), Error> {
        let str: ByteArray = format!(
            "Transaction {{ version: {}, overwintered: {}, version_group_id: {}, branch_id: {}, inputs: {}, outputs: {}, lock_time: {}, expiry_height: {}, sapling_balance: {}, orchard_balance: {}, is_segwit: {} }}",
            *self.version,
            self.overwintered.unwrap_or(false),
            self.version_group_id.unwrap_or(0),
            self.consensus_branch_id.unwrap_or(0),
            (*self.inputs).len(),
            (*self.outputs).len(),
            *self.lock_time,
            self.expiry_height.unwrap_or(0),
            self.value_balance_sapling.unwrap_or(0),
            self.value_balance_orchard.unwrap_or(0),
            *self.is_segwit,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Display` trait implementation for `TxIn`.
impl TxInDisplay of Display<TxIn> {
    fn fmt(self: @TxIn, ref f: Formatter) -> Result<(), Error> {
        let str: ByteArray = format!(
            "TxIn {{ script: {}, sequence: {}, previous_output: {} }}",
            *self.script,
            *self.sequence,
            *self.previous_output.txid,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Display` trait implementation for `OutPoint`.
impl OutPointDisplay of Display<OutPoint> {
    fn fmt(self: @OutPoint, ref f: Formatter) -> Result<(), Error> {
        let str: ByteArray = format!(
            "OutPoint {{
		txid: {},
		vout: {},
		data: {},
		block_height: {},
		median_time_past: {},
		is_coinbase: {},
	}}",
            *self.txid,
            *self.vout,
            *self.data,
            *self.block_height,
            *self.median_time_past,
            *self.is_coinbase,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Display` trait implementation for `TxOut`.
impl TxOutDisplay of Display<TxOut> {
    fn fmt(self: @TxOut, ref f: Formatter) -> Result<(), Error> {
        let str: ByteArray = format!(
            "TxOut {{ value: {}, pk_script: {}, cached: {} }}",
            *self.value,
            *self.pk_script,
            *self.cached,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

#[cfg(test)]
mod tests {
    use core::poseidon::PoseidonTrait;
    use utils::hex::{from_hex, hex_to_hash_rev};
    use super::{HashStateExTrait, HashStateTrait, OutPoint, OutPointHashTrait, TxOut};

    fn hash(tx: @TxOut) -> felt252 {
        PoseidonTrait::new().update_with(*tx).finalize()
    }

    #[test]
    pub fn test_txout_cached_flag_does_not_influence_hash() {
        let mut tx1 = TxOut {
            value: 50_u64,
            pk_script: @"410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac",
            cached: false,
        };
        let mut tx_with_cached_changed = TxOut {
            value: 50_u64,
            pk_script: @"410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac",
            cached: true,
        };
        let mut tx_with_value_changed = TxOut {
            value: 55_u64,
            pk_script: @"410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac",
            cached: false,
        };
        let mut tx_with_pk_script_changed = TxOut {
            value: 50_u64,
            pk_script: @"510411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac",
            cached: false,
        };
        assert_eq!(hash(@tx1), hash(@tx_with_cached_changed));
        assert_ne!(hash(@tx1), hash(@tx_with_pk_script_changed));
        assert_ne!(hash(@tx1), hash(@tx_with_value_changed));
    }

    #[derive(Debug, Drop, Default)]
    pub struct HashState {
        pub value: Array<felt252>,
    }

    impl HashStateImpl of HashStateTrait<HashState> {
        fn update(self: HashState, value: felt252) -> HashState {
            let mut new_value = self.value;
            new_value.append(value);
            HashState { value: new_value }
        }

        fn finalize(self: HashState) -> felt252 {
            0
        }
    }

    #[test]
    pub fn test_outpoint_poseidon_hash_cb9() {
        let mut coinbase_9_utxo = OutPoint {
            txid: hex_to_hash_rev(
                "0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9",
            ),
            vout: 0,
            data: TxOut {
                value: 5000000000,
                pk_script: @from_hex(
                    "410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac",
                ),
                cached: false,
            },
            block_height: 9,
            median_time_past: 1231470988,
            is_coinbase: true,
        };

        let mut state: HashState = Default::default();
        state = state.update_with(coinbase_9_utxo);

        let expected: Array<felt252> = array![
            5606656307511680658662848977137541728, 9103019671783490751638296454939121609, 0,
            5000000000, 2,
            114873147639302600539941532864842037771792291166958548649371950632810924198,
            255491345418700057264349667014908841246825595399329019948869966327385048054,
            372388307884, 5, 9, 1231470988, 1,
        ];
        assert_eq!(expected, state.value);

        let hash = coinbase_9_utxo.hash();
        assert_eq!(
            761592244424273723796345514960638980240531938129162865626185984897576522513, hash,
        );
    }

    #[test]
    pub fn test_outpoint_poseidon_hash_cb1() {
        let mut coinbase_9_utxo = OutPoint {
            txid: hex_to_hash_rev(
                "0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098",
            ),
            vout: 0,
            data: TxOut {
                value: 5000000000,
                pk_script: @from_hex(
                    "410496b538e853519c726a2c91e61ec11600ae1390813a627c66fb8be7947be63c52da7589379515d4e0a604f8141781e62294721166bf621e73a82cbf2342c858eeac",
                ),
                cached: false,
            },
            block_height: 1,
            median_time_past: 1231006505,
            is_coinbase: true,
        };

        let mut state: HashState = Default::default();
        state = state.update_with(coinbase_9_utxo);

        let expected: Array<felt252> = array![
            18931831195212887181660290436187791739, 137019159177035157628276746705882390680, 0,
            5000000000, 2,
            114876729272917404712191936498804624660105992100397383656070609774475449467,
            406791163401893627439198994794895943141891052128672824792182596804809637667,
            286829113004, 5, 1, 1231006505, 1,
        ];
        assert_eq!(expected, state.value);

        let hash = coinbase_9_utxo.hash();
        assert_eq!(
            49459078824306138476779209834441505868925737545954320330266544605873965565, hash,
        );
    }
}
