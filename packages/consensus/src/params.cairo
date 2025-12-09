//! Zcash consensus parameters used across Cairo modules.
//!
//! Sourced from https://github.com/zcash/zcash/blob/master/src/chainparams.cpp
//! and https://zips.z.cash/protocol/protocol.pdf.

// =============================================================================
// Genesis block parameters
// =============================================================================

pub const GENESIS_BLOCK_HASH: u256 =
    0x00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08_u256;

pub const GENESIS_MERKLE_ROOT: u256 =
    0xc4eaa58879081de3c24a7b117ed2b28300e7ec4c4c1dff1d3f1268b7857a4ddb_u256;

pub const GENESIS_TIME: u32 = 1477641360_u32;

pub const GENESIS_BITS: u32 = 0x1f07ffff_u32;

/// Zcash mainnet PoW limit (maximum target / easiest allowed difficulty).
/// From zcashd: consensus.powLimit =
/// uint256S("0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
/// This is used for consensus validation (clamping difficulty adjustments, validating nBits).
pub const POW_LIMIT: u256 = 0x0007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff_u256;

/// Expanded target corresponding to difficulty = 1 (genesis.nBits = 0x1f07ffff).
/// This is the reference point for difficulty calculations and display.
pub const DIFF1_TARGET: u256 =
    0x0007ffff00000000000000000000000000000000000000000000000000000000_u256;

/// Work contributed by the genesis block.
pub const GENESIS_TOTAL_WORK: u256 = 0x2000_u256;

// =============================================================================
// Network upgrade activation heights (Zcash mainnet)
// =============================================================================

/// Overwinter activation height (ZIP 200, 201, 202, 203, 143).
/// Introduces versioned transactions (v3), new signature hash, expiry height.
pub const OVERWINTER_ACTIVATION_HEIGHT: u32 = 347500_u32;

/// Sapling activation height (ZIP 205, 212, 213, 243).
/// Introduces Sapling shielded transactions, Groth16 proofs.
pub const SAPLING_ACTIVATION_HEIGHT: u32 = 419200_u32;

/// Blossom activation height (ZIP 208).
/// Reduces block target spacing from 150s to 75s.
pub const BLOSSOM_ACTIVATION_HEIGHT: u32 = 653600_u32;

/// Heartwood activation height (ZIP 213, 221).
/// Changes hashBlockCommitments field in block header.
/// Before Heartwood: hashFinalSaplingRoot
/// After Heartwood: hashLightClientRoot (includes Sapling + Orchard commitments)
pub const HEARTWOOD_ACTIVATION_HEIGHT: u32 = 903000_u32;

/// Canopy activation height (ZIP 211, 212, 214, 215, 216).
/// Introduces ZIP 212 Sapling changes, deprecates Sprout.
pub const CANOPY_ACTIVATION_HEIGHT: u32 = 1046400_u32;

/// NU5 (Orchard) activation height (ZIP 224, 225, 226, 227, 244).
/// Introduces Orchard shielded protocol with Halo2 proofs.
pub const NU5_ACTIVATION_HEIGHT: u32 = 1687104_u32;

// =============================================================================
// Equihash parameters
// =============================================================================

/// Equihash solution size for Zcash: 1344 bytes (n=200, k=9).
pub const EQUIHASH_N: u32 = 200;
pub const EQUIHASH_K: u32 = 9;
pub const EQUIHASH_SOLUTION_SIZE_BYTES: usize = 1344;
pub const EQUIHASH_SOLUTION_WORDS: usize = EQUIHASH_SOLUTION_SIZE_BYTES / 4;
pub const EQUIHASH_INDICES_TOTAL: usize = 512;
pub const EQUIHASH_INDICES_MAX: u32 = 2097151_u32; // 2^21 - 1
pub const EQUIHASH_HASH_OUTPUT_LENGTH: u8 = 50;

/// Equihash Blake2b personalization as two little-endian u64 words.
/// Represents: "ZcashPoW" (8 bytes) + n=200 as LE u32 + k=9 as LE u32
pub const EQUIHASH_PERSONALIZATION: [u64; 2] = [
    0x576f50687361635a_u64, // "ZcashPoW" as LE u64
    0x00000009000000c8_u64 // n=200, k=9 as LE u32s
];

// =============================================================================
// Block timing parameters
// =============================================================================

/// Block spacing parameters (in seconds).
pub const PRE_BLOSSOM_POW_TARGET_SPACING: u32 = 150_u32;
pub const POST_BLOSSOM_POW_TARGET_SPACING: u32 = 75_u32;

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

// =============================================================================
// Network upgrade helper functions
// =============================================================================

/// Returns true if Blossom is active at the given height.
pub fn is_blossom_active(height: u32) -> bool {
    height >= BLOSSOM_ACTIVATION_HEIGHT
}


/// Returns the expected PoW target spacing for a given block height.
pub fn pow_target_spacing(height: u32) -> u32 {
    if is_blossom_active(height) {
        POST_BLOSSOM_POW_TARGET_SPACING
    } else {
        PRE_BLOSSOM_POW_TARGET_SPACING
    }
}
