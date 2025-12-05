//! Types representing the compressed SPV proof and helpers to decode Cairo outputs
//! and compute chain state digests used during verification.

use cairo_air::CairoProof;
use serde::{Deserialize, Serialize};
use starknet_ff::FieldElement;
use stwo_prover::core::vcs::blake2_hash::Blake2sHasher;
use stwo_prover::core::vcs::blake2_merkle::Blake2sMerkleHasher;
use zcash_client::serialize::{
    deserialize_header, deserialize_transaction, serialize_header, serialize_transaction,
};
use zcash_client::MerkleProof;
use zebra_chain::block::Hash;
use zebra_chain::block::Header;
use zebra_chain::transaction::Transaction;

/// Zcash transaction inclusion data in a specific block
#[derive(Serialize, Deserialize)]
pub struct TransactionInclusionProof {
    /// The full Bitcoin transaction being proven
    #[serde(
        serialize_with = "serialize_transaction",
        deserialize_with = "deserialize_transaction"
    )]
    pub transaction: Transaction,
    /// Encoded PartialMerkleTree containing the Merkle path for the transaction
    pub transaction_proof: MerkleProof,
    /// Header of the block that includes the transaction
    #[serde(
        serialize_with = "serialize_header",
        deserialize_with = "deserialize_header"
    )]
    pub block_header: Header,
    /// Height of the block that includes the transaction
    pub block_height: u32,
}

/// A compact, self-contained proof that a Bitcoin transaction is included
/// in a specific block and that the block is part of a valid chain state.
#[derive(Serialize, Deserialize)]
pub struct CompressedSpvProof {
    /// The current state of the chain
    pub chain_state: ChainState,
    /// Recursive STARK proof of the chain state and block MMR root validity
    pub chain_state_proof: CairoProof<Blake2sMerkleHasher>,
    /// The header of the block containing the transaction
    #[serde(
        serialize_with = "serialize_header",
        deserialize_with = "deserialize_header"
    )]
    pub block_header: Header,
    /// MMR inclusion proof for the block header
    pub block_header_proof: Vec<u8>, // ToDo: adapt for fly client
    /// The transaction to be proven
    #[serde(
        serialize_with = "serialize_transaction",
        deserialize_with = "deserialize_transaction"
    )]
    pub transaction: Transaction,
    /// Encoded [MerkleTree] structure, contains Merkle branch for the transaction
    pub transaction_proof: MerkleProof,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Target([u8; 32]);

impl Target {
    pub fn from_hex(hex: &str) -> anyhow::Result<Self> {
        let bytes = hex::decode(hex)?;
        if bytes.len() != 32 {
            return Err(anyhow::anyhow!("Invalid target length"));
        }
        Ok(Self(bytes.try_into().unwrap()))
    }

    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }
}

/// Snapshot of the consensus chain state used to validate block inclusion
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainState {
    /// The height of the best block in the chain
    pub block_height: u32,
    /// The total accumulated work of the chain
    pub total_work: u128,
    /// The hash of the best block in the chain
    pub best_block_hash: Hash,
    /// The current target difficulty
    pub current_target: Target,
    /// The start time (UNIX seconds) of the current difficulty epoch
    pub prev_timestamps: Vec<u32>,
    /// Timestamp of the block that started the current difficulty epoch (legacy field kept for
    /// serialization compatibility)
    pub epoch_start_time: u32,
    /// Difficulty targets (u256) of the most recent blocks as decimal strings
    pub pow_target_history: Vec<Target>,
}

/// Output of the bootloader program
#[derive(Debug, Clone)]
pub struct BootloaderOutput {
    /// Number of tasks (must be always 1)
    pub n_tasks: u32,
    /// Size of the task output in felts (including the size field)
    pub task_output_size: u32,
    /// Hash of the payload program.
    pub task_program_hash: String,
    /// Output of the payload program.
    pub task_result: TaskResult,
}

/// Output of the payload program
#[derive(Debug, Clone)]
pub struct TaskResult {
    /// Hash of the chain state after the blocks have been applied.
    pub chain_state_hash: String,
    /// Hash of the roots of the Merkle Mountain Range of the block hashes.
    pub block_mmr_hash: String,
    /// Hash of the previous bootloader program that was recursively verified.
    /// We do not hardcode the bootloader hash in the assumevalid program,
    /// letting the final verifier to check that it is as expected.
    pub bootloader_hash: String,
    /// Hash of the assumevalid program that was recursively verified.
    /// We cannot know the hash of the program from within the program, so we have to carry it over.
    /// This also allows composing multiple programs (e.g. if we'd need to upgrade at a certain
    /// block height).
    pub program_hash: String,
}

impl BootloaderOutput {
    /// Decode `BootloaderOutput` from the Cairo public output felts emitted by the bootloader.
    pub fn decode(mut output: Vec<FieldElement>) -> anyhow::Result<Self> {
        let n_tasks = output
            .remove(0)
            .try_into()
            .map_err(|_| anyhow::anyhow!("Expected number of tasks to be a u32"))?;
        let task_output_size = output
            .remove(0)
            .try_into()
            .map_err(|_| anyhow::anyhow!("Expected task output size to be a u32"))?;
        let task_program_hash = decode_truncated_hash(&mut output)?;
        let task_result = TaskResult::decode(output)?;
        Ok(Self {
            n_tasks,
            task_output_size,
            task_program_hash,
            task_result,
        })
    }
}

impl TaskResult {
    /// Decode `TaskResult` from the remainder of the Cairo public output felts.
    pub fn decode(mut output: Vec<FieldElement>) -> anyhow::Result<Self> {
        let chain_state_hash = decode_hash(&mut output)?;
        let block_mmr_hash = decode_hash(&mut output)?;
        let prev_bootloader_hash = decode_truncated_hash(&mut output)?;
        let prev_program_hash = decode_truncated_hash(&mut output)?;
        Ok(Self {
            chain_state_hash,
            block_mmr_hash,
            bootloader_hash: prev_bootloader_hash,
            program_hash: prev_program_hash,
        })
    }
}

fn decode_hash(output: &mut Vec<FieldElement>) -> anyhow::Result<String> {
    // In Cairo serde u256 low goes first, high goes second
    let lo: u128 = output.remove(0).try_into().unwrap();
    let hi: u128 = output.remove(0).try_into().unwrap();
    let bytes = [hi.to_be_bytes(), lo.to_be_bytes()].concat();
    Ok(format!("0x{}", hex::encode(bytes)))
}

fn decode_truncated_hash(output: &mut Vec<FieldElement>) -> anyhow::Result<String> {
    let bytes = output.remove(0).to_bytes_be();
    Ok(format!("0x{}", hex::encode(bytes)))
}

impl ChainState {
    /// Compute the Blake2s digest of the canonical serialization of the chain state.
    ///
    /// The serialization mirrors the Cairo-side little-endian encoding.
    pub fn blake2s_digest(&self) -> anyhow::Result<String> {
        // Construct the payload for the hash function, mirroring Cairo's word order.
        let mut words: Vec<u32> = Vec::new();

        // Height
        words.push(self.block_height);

        // Total work: treat u128 as a u256 with zero high half, then split into 8 big-endian u32 words.
        let mut total_work_bytes = [0u8; 32];
        total_work_bytes[16..].copy_from_slice(&self.total_work.to_be_bytes());
        words.extend(split_bytes_into_words(&total_work_bytes));

        // Best block hash (32-byte big-endian value -> 8 u32 words).
        words.extend(split_bytes_into_words(&self.best_block_hash.0));

        // Current target (u256 encoded as 32-byte big-endian value).
        words.extend(split_bytes_into_words(&self.current_target.0));

        // Previous timestamps.
        words.extend(self.prev_timestamps.iter().copied());

        // PoW target history: each target is a 32-byte big-endian u256.
        for target in &self.pow_target_history {
            words.extend(split_bytes_into_words(&target.0));
        }

        // Epoch start time.
        words.push(self.epoch_start_time);

        // Serialize to bytes, using little-endian encoding for each word.
        let bytes = words
            .iter()
            .flat_map(|word| word.to_le_bytes())
            .collect::<Vec<_>>();

        // Compute the hash
        let mut hasher = Blake2sHasher::new();
        hasher.update(&bytes);
        let mut digest_bytes = hasher.finalize().0.to_vec();

        // Reverse bytes in each 4-byte chunk, to comply with Cairo's little-endian encoding.
        digest_bytes.chunks_exact_mut(4).for_each(|chunk| {
            chunk.reverse();
        });
        let res = format!("0x{}", hex::encode(digest_bytes));
        Ok(res)
    }
}

fn split_bytes_into_words(bytes: &[u8]) -> Vec<u32> {
    bytes
        .chunks_exact(4)
        .map(|chunk| u32::from_be_bytes(chunk.try_into().unwrap()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex::FromHex;

    #[test]
    fn test_chain_state_hash() {
        let chain_state = ChainState {
            block_height: 0,
            total_work: 0x2000,
            best_block_hash: Hash::from_hex(
                "00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08",
            )
            .unwrap(),
            current_target: Target::from_hex(
                "0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            )
            .unwrap(),
            prev_timestamps: vec![1477641360],
            epoch_start_time: 1477641360,
            pow_target_history: vec![
                Target::from_hex(
                    "0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                )
                .unwrap();
                17
            ],
        };
        let res = chain_state.blake2s_digest().unwrap();
        let expected = "0x5f075316d513cf571854e8f4df77f22ce7bfae4c7a1b271d57d9dfb61a54e2ec";
        assert_eq!(res, expected);
    }

    #[test]
    fn test_decode_hash() {
        let mut output = vec![
            FieldElement::from_dec_str("336341903543133962954146260045611975739").unwrap(),
            FieldElement::from_dec_str("127621031286465709630765493168293005461").unwrap(),
        ];
        let res = decode_hash(&mut output).unwrap();
        let expected = "0x6002eaa4410bd0b15e778656f84fc895fd091827e27ce697ba4231076c70c43b";
        assert_eq!(res, expected);
    }
}
