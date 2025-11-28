//! Chain state is a minimal subset of data required to unambiguously
//! define a particular blockchain starting at the genesis.
//!
//! Chain state alone is not enough to do full block validation, however
//! it is sufficient to validate block headers.

use consensus::params::{
    DIFF1_TARGET, GENESIS_BLOCK_HASH, GENESIS_TIME, GENESIS_TOTAL_WORK, POW_AVERAGING_WINDOW,
};
use core::fmt::{Display, Error, Formatter};
use core::hash::{Hash, HashStateExTrait, HashStateTrait};
use core::serde::Serde;
use utils::blake2s_hasher::{Blake2sDigest, Blake2sDigestIntoU256, Blake2sHasher};
use utils::hash::Digest;
use utils::numeric::u256_to_u32x8;

/// Represents the state of the blockchain.
#[derive(Drop, Copy, Debug, PartialEq)]
pub struct ChainState {
    /// Height of the current block.
    pub block_height: u32,
    /// Total work done.
    pub total_work: u256,
    /// Best block.
    pub best_block_hash: Digest,
    /// Current target (nBits) that the next block must satisfy.
    pub current_target: u256,
    /// Chronological list of recent block timestamps used for computing the Median Time Past rule.
    pub prev_timestamps: Span<u32>,
    /// Timestamp of the block that started the current difficulty epoch (legacy field kept for
    /// serialization compatibility).
    pub epoch_start_time: u32,
    /// Difficulty targets (converted from `nBits`) of the most recent blocks, capped to the
    /// averaging window size.
    pub pow_target_history: Span<u256>,
}

/// `ChainState` Poseidon hash implementation.
#[generate_trait]
pub impl ChainStateHashImpl of ChainStateHashTrait {
    /// Returns the Blake2s digest of the chain state.
    /// NOTE: returned u256 value is little-endian.
    fn blake2s_digest(self: @ChainState) -> Blake2sDigest {
        let [tw0, tw1, tw2, tw3, tw4, tw5, tw6, tw7] = u256_to_u32x8(*self.total_work);
        let [bh0, bh1, bh2, bh3, bh4, bh5, bh6, bh7] = *self.best_block_hash.value;
        let [ct0, ct1, ct2, ct3, ct4, ct5, ct6, ct7] = u256_to_u32x8(*self.current_target);

        let mut words: Array<u32> = array![
            *self.block_height, tw0, tw1, tw2, tw3, tw4, tw5, tw6, tw7, bh0, bh1, bh2, bh3, bh4,
            bh5, bh6,
        ];
        words.append(bh7);
        words.append(ct0);
        words.append(ct1);
        words.append(ct2);
        words.append(ct3);
        words.append(ct4);
        words.append(ct5);
        words.append(ct6);
        words.append(ct7);
        for ts in *self.prev_timestamps {
            words.append(*ts);
        }
        for target in *self.pow_target_history {
            let [p0, p1, p2, p3, p4, p5, p6, p7] = u256_to_u32x8(*target);
            words.append(p0);
            words.append(p1);
            words.append(p2);
            words.append(p3);
            words.append(p4);
            words.append(p5);
            words.append(p6);
            words.append(p7);
        }
        words.append(*self.epoch_start_time);

        let mut hasher = Blake2sHasher::new();

        let mut blocks = words.span();
        while let Option::Some(chunk) = blocks.multi_pop_front::<16>() {
            hasher.compress_block((*chunk).unbox());
        }

        let mut tail: Array<u32> = array![];
        for word in blocks {
            tail.append(*word);
        }

        hasher.finalize(tail.span())
    }
}

/// `Default` implementation of `ChainState` representing the initial state after genesis block on
/// Zcash mainnet.
impl ChainStateDefault of Default<ChainState> {
    fn default() -> ChainState {
        ChainState {
            block_height: 0,
            total_work: GENESIS_TOTAL_WORK,
            best_block_hash: GENESIS_BLOCK_HASH.into(),
            current_target: DIFF1_TARGET,
            prev_timestamps: [GENESIS_TIME].span(),
            pow_target_history: seed_pow_history(DIFF1_TARGET),
            epoch_start_time: GENESIS_TIME,
        }
    }
}

/// `Display` trait implementation for `ChainState`.
impl ChainStateDisplay of Display<ChainState> {
    fn fmt(self: @ChainState, ref f: Formatter) -> Result<(), Error> {
        let mut prev_ts: ByteArray = Default::default();
        for ts in *self.prev_timestamps {
            prev_ts.append(@format!("{},", ts));
        }
        let str: ByteArray = format!(
            "
	block_height: {}
	total_work: {}
	best_block_hash: {}
	current_target: {}
	prev_timestamps: [{}]
	pow_target_history_len: {}
	epoch_start_time: {}
}}",
            *self.block_height,
            *self.total_work,
            *self.best_block_hash,
            *self.current_target,
            @prev_ts,
            self.pow_target_history.len(),
            *self.epoch_start_time,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

impl ChainStateSerde of Serde<ChainState> {
    fn serialize(self: @ChainState, ref output: Array<felt252>) {
        Serde::serialize(self.block_height, ref output);
        Serde::serialize(self.total_work, ref output);
        Serde::serialize(self.best_block_hash, ref output);
        Serde::serialize(self.current_target, ref output);
        Serde::serialize(self.prev_timestamps, ref output);
        Serde::serialize(self.epoch_start_time, ref output);
        Serde::serialize(self.pow_target_history, ref output);
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<ChainState> {
        let block_height = Serde::deserialize(ref serialized)?;
        let total_work = Serde::deserialize(ref serialized)?;
        let best_block_hash = Serde::deserialize(ref serialized)?;
        let current_target = Serde::deserialize(ref serialized)?;
        let prev_timestamps = Serde::deserialize(ref serialized)?;

        let epoch_start_time = Serde::deserialize(ref serialized)?;

        let pow_target_history = if serialized.len() > 0 {
            Serde::deserialize(ref serialized)?
        } else {
            array![].span()
        };
        let pow_target_history = ensure_pow_history(pow_target_history, current_target);

        Option::Some(
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
}

pub fn ensure_pow_history(history: Span<u256>, target: u256) -> Span<u256> {
    if history.is_empty() {
        seed_pow_history(target)
    } else {
        history
    }
}

fn seed_pow_history(target: u256) -> Span<u256> {
    let mut history: Array<u256> = array![];
    let mut count = 0;
    loop {
        history.append(target);
        count += 1;
        if count == POW_AVERAGING_WINDOW {
            break;
        }
    }
    history.span()
}

/// `Hash` trait implementation for `Span<T>` where T implements `Hash` and `Copy`.
/// Required for `ChainState` to be `Hash`able.
impl SpanHash<S, +HashStateTrait<S>, +Drop<S>, T, +Hash<T, S>, +Copy<T>> of Hash<Span<T>, S> {
    fn update_state(state: S, value: Span<T>) -> S {
        let mut state = state;
        for element in value {
            state = state.update_with(*element);
        }
        state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chain_state_hash() {
        let chain_state: ChainState = Default::default();
        let digest: u256 = chain_state.blake2s_digest().into();
        // Verify hash is deterministic by computing it twice
        let digest2: u256 = chain_state.blake2s_digest().into();
        assert_eq!(digest, digest2, "Chain state hash should be deterministic");
        assert!(digest != 0_u256, "Chain state hash should not be zero");
    }

    #[test]
    fn test_default_pow_history_seeded() {
        let chain_state: ChainState = Default::default();
        assert_eq!(chain_state.pow_target_history.len(), POW_AVERAGING_WINDOW);
        assert_eq!(
            *chain_state.pow_target_history[0],
            DIFF1_TARGET,
            "expected history to be initialized with DIFF1_TARGET",
        );
    }

    #[test]
    fn test_ensure_pow_history_seeds_missing_history() {
        let empty_history = array![].span();
        let seeded = ensure_pow_history(empty_history, 42_u256);
        assert_eq!(seeded.len(), POW_AVERAGING_WINDOW);
        assert_eq!(*seeded[0], 42_u256);
    }
}
