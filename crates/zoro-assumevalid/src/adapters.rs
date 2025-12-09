//! Adapters for converting Zcash types to Cairo-compatible structures
//!
//! This module provides serialization from Rust types to the format expected by
//! the Cairo program defined in packages/client/src/test.cairo

use cairo_air::CairoProof;
use stwo::core::vcs::blake2_merkle::Blake2sMerkleHasher;
use stwo_cairo_serialize::CairoSerialize;

use zebra_chain::block::Header;
use zebra_chain::serialization::ZcashSerialize;
use zoro_spv_verify::ChainState;

use num_bigint::BigUint;
use num_traits::Num;
use starknet_ff::FieldElement;

// ============================================================================
// Cairo serialization wrapper types
// ============================================================================

/// u256 serialized as (lo: u128, hi: u128) from decimal string
#[derive(Clone)]
pub struct U256String(pub String);
#[derive(Clone)]
pub struct ByteArrayString(pub String);
#[derive(Clone)]
pub struct DigestString(pub String);
pub struct U256StringLittleEndian(pub String);

impl CairoSerialize for U256String {
    fn serialize(&self, output: &mut Vec<FieldElement>) {
        // Accept decimal string only, produce 32-byte big-endian
        let s = self.0.trim();
        assert!(
            !s.starts_with("0x") && !s.starts_with("0X"),
            "Hex not supported for U256String; use decimal",
        );
        let n = BigUint::from_str_radix(s, 10).expect("Invalid decimal string for U256");
        let bytes = n.to_bytes_be();
        assert!(bytes.len() <= 32, "U256 value exceeds 256 bits");
        let mut be = [0u8; 32];
        be[32 - bytes.len()..].copy_from_slice(&bytes);

        // lo = least-significant 16 bytes, hi = most-significant 16 bytes
        let (hi16, lo16) = be.split_at(16);

        let mut lo_bytes = [0u8; 32];
        lo_bytes[16..].copy_from_slice(lo16);
        let mut hi_bytes = [0u8; 32];
        hi_bytes[16..].copy_from_slice(hi16);

        output.push(FieldElement::from_bytes_be(&lo_bytes).unwrap());
        output.push(FieldElement::from_bytes_be(&hi_bytes).unwrap());
    }
}

impl CairoSerialize for U256StringLittleEndian {
    fn serialize(&self, output: &mut Vec<FieldElement>) {
        // Accept decimal string only, produce 32-byte big-endian
        let s = self.0.trim();
        assert!(
            !s.starts_with("0x") && !s.starts_with("0X"),
            "Hex not supported for U256StringHiLo; use decimal",
        );
        let n = BigUint::from_str_radix(s, 10).expect("Invalid decimal string for U256");
        let bytes = n.to_bytes_be();
        assert!(bytes.len() <= 32, "U256 value exceeds 256 bits");
        let mut be = [0u8; 32];
        be[32 - bytes.len()..].copy_from_slice(&bytes);

        // hi = most-significant 16 bytes, lo = least-significant 16 bytes
        let (lo16, hi16) = be.split_at(16);

        let mut hi_bytes = [0u8; 32];
        hi_bytes[16..].copy_from_slice(hi16);
        let mut lo_bytes = [0u8; 32];
        lo_bytes[16..].copy_from_slice(lo16);

        // Note: emit HI first, then LO to match Cairo MMR Serde (high, low)
        output.push(FieldElement::from_bytes_be(&lo_bytes).unwrap());
        output.push(FieldElement::from_bytes_be(&hi_bytes).unwrap());
    }
}

impl CairoSerialize for ByteArrayString {
    // Split into 31-byte chunks and save the remainder
    fn serialize(&self, output: &mut Vec<FieldElement>) {
        let s = self.0.as_str();
        let hex_str = if s.starts_with("0x") || s.starts_with("0X") {
            s.to_string()
        } else {
            format!("0x{}", hex::encode(s.as_bytes()))
        };

        // Remove 0x prefix
        let hex_data = hex_str.strip_prefix("0x").unwrap_or(&hex_str);
        let bytes = hex::decode(hex_data).expect("Invalid hex string");

        // Calculate chunks and remainder
        let chunk_size = 31; // 31 bytes per chunk (248 bits, fits in felt252)
        let num_chunks = bytes.len() / chunk_size;
        let remainder_len = bytes.len() % chunk_size;

        // Serialize: num_chunks, chunks..., remainder, rem_len
        output.push(FieldElement::from(num_chunks as u128));

        // Serialize chunks
        for chunk in bytes.chunks(chunk_size) {
            if chunk.len() == chunk_size {
                let mut chunk_bytes = [0u8; 32];
                chunk_bytes[1..=chunk_size].copy_from_slice(chunk);
                output.push(FieldElement::from_bytes_be(&chunk_bytes).unwrap());
            }
        }

        // Serialize remainder
        if remainder_len > 0 {
            let remainder = &bytes[bytes.len() - remainder_len..];
            let mut rem_bytes = [0u8; 32];
            let start = 32 - remainder_len;
            rem_bytes[start..].copy_from_slice(remainder);
            output.push(FieldElement::from_bytes_be(&rem_bytes).unwrap());
        } else {
            output.push(FieldElement::from(0u8));
        }

        output.push(FieldElement::from(remainder_len as u128));
    }
}

impl CairoSerialize for DigestString {
    // Reversed hex string into 4-byte words then into BE u32
    fn serialize(&self, output: &mut Vec<FieldElement>) {
        let s = self.0.as_str();
        let hex_str = s
            .strip_prefix("0x")
            .or_else(|| s.strip_prefix("0X"))
            .unwrap_or(s);

        // Convert 64-char hex to 8 u32 words (reversed for little-endian)
        let bytes = hex::decode(hex_str).expect("Invalid hex string");
        assert!(bytes.len() == 32, "expected 32-byte digest");
        let mut rev = bytes;
        rev.reverse();
        for chunk in rev.chunks(4) {
            let mut word_bytes = [0u8; 4];
            word_bytes[..chunk.len()].copy_from_slice(chunk);
            let word = u32::from_be_bytes(word_bytes) as u128;
            output.push(FieldElement::from(word));
        }
    }
}

// ============================================================================
// Cairo-compatible view structures matching packages/consensus/src/types/
// ============================================================================

/// View for test.cairo Args struct that matches Cairo's structure
#[derive(CairoSerialize)]
struct ArgsView {
    chain_state: ChainStateView,
    blocks: Vec<BlockView>,
    chain_state_proof: Option<CairoProof<Blake2sMerkleHasher>>,
}

/// View matching Cairo `ChainState` layout from consensus/src/types/chain_state.cairo
/// Serialization order must match ChainStateSerde in Cairo
#[derive(CairoSerialize)]
struct ChainStateView {
    block_height: u32,
    total_work: U256String,
    best_block_hash: DigestString,
    current_target: U256String,
    prev_timestamps: Vec<u32>,
    epoch_start_time: u32,
    pow_target_history: Vec<U256String>,
}

/// View for a single block matching Cairo's Block structure from consensus/src/types/block.cairo
#[derive(CairoSerialize)]
struct BlockView {
    header: HeaderView,
    /// TransactionData enum - variant 0 = MerkleRoot
    data: TransactionDataView,
}

/// TransactionData - manually implement CairoSerialize for enum
struct TransactionDataView {
    /// Merkle root digest
    merkle_root: DigestString,
}

impl CairoSerialize for TransactionDataView {
    fn serialize(&self, output: &mut Vec<FieldElement>) {
        0_usize.serialize(output);
        // Serialize the merkle root
        self.merkle_root.serialize(output);
    }
}

/// Zcash header view matching Cairo's Header from consensus/src/types/block.cairo
#[derive(CairoSerialize, Clone)]
struct HeaderView {
    /// Block version
    pub version: u32,
    /// Hash of the Sapling commitment tree (32 bytes as 8 u32 words)
    pub final_sapling_root: DigestString,
    /// Block timestamp
    pub time: u32,
    /// Difficulty target (nBits)
    pub bits: u32,
    /// 256-bit nonce (32 bytes as 8 u32 words)
    pub nonce: DigestString,
    /// Equihash solution words
    pub solution: Vec<u32>,
}

/// Main adapter function for test.cairo Args
pub fn to_runner_args_hex(
    chain_state: ChainState,
    headers: &[Header],
    expected_chain_state: ChainState,
) -> Vec<String> {
    // Convert headers to BlockView
    let blocks: Vec<BlockView> = headers
        .iter()
        .map(|header| {
            // Extract bits from difficulty_threshold
            let bits = u32::from_be_bytes(header.difficulty_threshold.bytes_in_display_order());

            // Serialize solution to get bytes, then convert to u32 words
            let mut solution_bytes = Vec::new();
            header
                .solution
                .zcash_serialize(&mut solution_bytes)
                .expect("solution serialization failed");
            // Skip the compact size prefix (1-3 bytes depending on size)
            let solution_data = if solution_bytes.len() > 1344 {
                // Has compact size prefix
                &solution_bytes[solution_bytes.len() - 1344..]
            } else {
                &solution_bytes[..]
            };
            let solution_words = extract_solution_words(solution_data);

            // Nonce needs byte reversal: internal order -> display order
            let nonce_reversed: Vec<u8> = header.nonce.0.iter().rev().cloned().collect();

            // Merkle root needs byte reversal: internal order -> display order
            let merkle_root_reversed: Vec<u8> =
                header.merkle_root.0.iter().rev().cloned().collect();

            BlockView {
                header: HeaderView {
                    version: header.version,
                    final_sapling_root: DigestString(hex::encode(*header.commitment_bytes)),
                    time: header.time.timestamp() as u32,
                    bits,
                    nonce: DigestString(hex::encode(&nonce_reversed)),
                    solution: solution_words,
                },
                data: TransactionDataView {
                    merkle_root: DigestString(hex::encode(&merkle_root_reversed)),
                },
            }
        })
        .collect();

    let chain_state_view = chain_state_to_view(chain_state);

    let args_view = ArgsView {
        chain_state: chain_state_view,
        blocks,
        chain_state_proof: None,
    };

    let mut felts = Vec::new();
    args_view.serialize(&mut felts);

    felts
        .into_iter()
        .map(|felt| format!("0x{felt:x}"))
        .collect()
}

fn chain_state_to_view(chain_state: ChainState) -> ChainStateView {
    let pow_target_history: Vec<U256String> = chain_state
        .pow_target_history
        .iter()
        .map(|target| U256String(bytes_to_decimal_string(target.as_bytes())))
        .collect();

    // best_block_hash needs byte reversal: internal order -> display order
    let hash_reversed: Vec<u8> = chain_state
        .best_block_hash
        .0
        .iter()
        .rev()
        .cloned()
        .collect();

    ChainStateView {
        block_height: chain_state.block_height,
        total_work: U256String(chain_state.total_work.to_string()),
        best_block_hash: DigestString(hex::encode(&hash_reversed)),
        current_target: U256String(bytes_to_decimal_string(
            chain_state.current_target.as_bytes(),
        )),
        prev_timestamps: chain_state.prev_timestamps.clone(),
        epoch_start_time: chain_state.epoch_start_time,
        pow_target_history,
    }
}

/// Extract Equihash solution as u32 words (little-endian as per Zcash spec)
fn extract_solution_words(solution_bytes: &[u8]) -> Vec<u32> {
    solution_bytes
        .chunks(4)
        .map(|chunk| {
            let mut bytes = [0u8; 4];
            bytes[..chunk.len()].copy_from_slice(chunk);
            u32::from_le_bytes(bytes)
        })
        .collect()
}

fn bytes_to_decimal_string(bytes: &[u8; 32]) -> String {
    let big_uint = BigUint::from_bytes_be(bytes);
    big_uint.to_str_radix(10)
}
