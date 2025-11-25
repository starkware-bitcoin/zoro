//! Zcash consensus parameters used across Cairo modules.
//!
//! Sourced from https://github.com/zcash/zcash/blob/master/src/chainparams.cpp
//! and https://zips.z.cash/protocol/protocol.pdf.

pub const GENESIS_BLOCK_HASH: u256 =
    0x00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08_u256;

pub const GENESIS_MERKLE_ROOT: u256 =
    0xc4eaa58879081de3c24a7b117ed2b28300e7ec4c4c1dff1d3f1268b7857a4ddb_u256;

pub const GENESIS_TIME: u32 = 1477641360_u32;

pub const GENESIS_BITS: u32 = 0x1f07ffff_u32;

/// The PoW limit (target max) encoded in nBits 0x1f07ffff.
pub const POW_LIMIT: u256 =
    0x0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff_u256;

/// Work contributed by the genesis block.
pub const GENESIS_TOTAL_WORK: u256 = 0x2000_u256;

/// Equihash solution size for Zcash: 1344 bytes (n=200, k=9).
pub const EQUIHASH_N: u32 = 200;
pub const EQUIHASH_K: u32 = 9;
pub const EQUIHASH_SOLUTION_SIZE_BYTES: usize = 1344;
pub const EQUIHASH_SOLUTION_WORDS: usize = EQUIHASH_SOLUTION_SIZE_BYTES / 4;

/// Block spacing parameters (in seconds).
pub const PRE_BLOSSOM_POW_TARGET_SPACING: u32 = 150_u32;
pub const POST_BLOSSOM_POW_TARGET_SPACING: u32 = 75_u32;

/// Height at which Blossom activates (switching to 75s spacing).
pub const BLOSSOM_ACTIVATION_HEIGHT: u32 = 653600_u32;

/// Parameters for the Zcash DigiShield-v3 adjustment.
pub const POW_AVERAGING_WINDOW: usize = 17;
pub const POW_MAX_ADJUST_DOWN: u32 = 32;
pub const POW_MAX_ADJUST_UP: u32 = 16;
pub const LEGACY_EPOCH_INTERVAL: u32 = 2016_u32;
pub const MAX_FUTURE_BLOCK_TIME_MTP: u32 = 70 * 60_u32; // 70 minutes
pub const MAX_FUTURE_BLOCK_TIME_LOCAL: u32 = 2 * 60 * 60_u32; // 2 hours

/// Number of timestamps used to compute the median-time-past.
pub const MEDIAN_TIME_WINDOW: usize = 11;
pub const MAX_TIMESTAMP_HISTORY: usize = POW_AVERAGING_WINDOW + MEDIAN_TIME_WINDOW;

/// Returns the expected PoW target spacing for a given block height.
pub fn pow_target_spacing(height: u32) -> u32 {
    if height >= BLOSSOM_ACTIVATION_HEIGHT {
        POST_BLOSSOM_POW_TARGET_SPACING
    } else {
        PRE_BLOSSOM_POW_TARGET_SPACING
    }
}

