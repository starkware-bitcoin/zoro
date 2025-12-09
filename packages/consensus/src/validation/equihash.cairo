// =======================
// Equihash helpers on top of our Blake2b
// =======================

use consensus::params::{EQUIHASH_INDICES_TOTAL, EQUIHASH_INDICES_MAX, EQUIHASH_N, EQUIHASH_K};
use consensus::types::block::Header;
use core::array::ArrayTrait;
use core::traits::{Into, TryInto};
use utils::bit_shifts::{pow32, shl64, shr64};
use utils::blake2b::blake2b_hash;
use utils::hash::Digest;

#[cfg(feature: "blake2b")]
use consensus::params::{EQUIHASH_HASH_OUTPUT_LENGTH, EQUIHASH_PERSONALIZATION};
#[cfg(feature: "blake2b")]
use core::blake::{Blake2bHasher, Blake2bHasherTrait, Blake2bParamsTrait};
#[cfg(feature: "blake2b")]
use core::traits::DivRem;

// 512-bit Blake2b output split into n-bit chunks
fn equihash_indices_per_hash_output(n: u32) -> u32 {
    // In librustzcash: indices_per_hash_output(n) = 512 / n
    512_u32 / n
}


// Convert u32 to 4-byte little-endian *fixed* array (no mutation, just a literal).
fn u32_to_le_4(x: u32) -> [u8; 4] {
    let x64: u64 = x.into();

    // Byte 0 = least significant
    let b0_u64: u64 = shr64(x64, 0_u32);
    let b0: u8 = (b0_u64 % 256_u64).try_into().unwrap();

    let b1_u64: u64 = shr64(x64, 8_u32);
    let b1: u8 = (b1_u64 % 256_u64).try_into().unwrap();

    let b2_u64: u64 = shr64(x64, 16_u32);
    let b2: u8 = (b2_u64 % 256_u64).try_into().unwrap();

    let b3_u64: u64 = shr64(x64, 24_u32);
    let b3: u8 = (b3_u64 % 256_u64).try_into().unwrap();

    [b0, b1, b2, b3]
}

// Same but as Array<u8>, convenient to append to an Array<u8> input.
fn u32_to_le_bytes_array(x: u32) -> Span<u8> {
    u32_to_le_4(x).span()
}

// Equihash personalization = "ZcashPoW" ++ n_le(u32) ++ k_le(u32).
fn equihash_personalization(n: u32, k: u32) -> [u8; 16] {
    let [n1, n2, n3, n4]: [u8; 4] = u32_to_le_4(n);
    let [k1, k2, k3, k4]: [u8; 4] = u32_to_le_4(k);

    [
        0x5a_u8, // 'Z'
        0x63_u8, // 'c'
        0x61_u8, // 'a'
        0x73_u8, // 's'
        0x68_u8, // 'h'
        0x50_u8, // 'P'
        0x6f_u8, // 'o'
        0x57_u8, // 'W'
        n1, n2, n3, n4, k1, k2, k3, k4,
    ]
}

// Core Equihash per-index hash:
// returns n/8 bytes for the logical index `idx`.
fn equihash_hash_index(header: Array<u8>, n: u32, k: u32, idx: u32) -> Span<u8> {
    let indices_per: u32 = equihash_indices_per_hash_output(n);
    let collision_bytes: u32 = n / 8_u32;
    let outlen: u32 = indices_per * collision_bytes;

    // Which Blake2b invocation and which chunk?
    let hash_input_index: u32 = idx / indices_per;
    let subindex: u32 = idx % indices_per;

    // input = header || le_u32(hash_input_index)
    let mut input = header;
    let idx_span: Span<u8> = u32_to_le_bytes_array(hash_input_index);
    input.append_span(idx_span);

    // personalization
    let pers: [u8; 16] = equihash_personalization(n, k);

    // full Blake2b output, length = indices_per * (n / 8)
    let full: Array<u8> = blake2b_hash(input, outlen, pers);

    // Take the subindex-th chunk of size collision_bytes
    let full_span = full.span();
    let start = subindex * collision_bytes; // in bytes

    full_span.slice(start, collision_bytes)
}


// =====================
// Node type
// =====================

#[derive(Drop)]
struct EquihashNode {
    hash: Array<u8>,
    indices: Array<u32>,
}

// =====================
// Small helpers (no Params struct)
// =====================

fn collision_bit_length(n: u32, k: u32) -> u32 {
    n / (k + 1_u32)
}

fn collision_byte_length(n: u32, k: u32) -> usize {
    let bits: u32 = collision_bit_length(n, k);
    let bytes: u32 = (bits + 7_u32) / 8_u32;
    bytes
}

// =====================
// Tree-related helpers
// =====================

fn has_collision(ref a: EquihashNode, ref b: EquihashNode, len: usize) -> bool {
    let mut ha = a.hash.span();
    let mut hb = b.hash.span();

    let mut i: usize = 0;
    while i < len {
        if ha.pop_front().unwrap() != hb.pop_front().unwrap() {
            return false;
        }
        i = i + 1_usize;
    }
    true
}

fn indices_before(a: @EquihashNode, b: @EquihashNode) -> bool {
    let mut ia = a.indices.span();
    let mut ib = b.indices.span();
    let a0: u32 = *ia.pop_front().unwrap();
    let b0: u32 = *ib.pop_front().unwrap();
    a0 < b0
}

fn from_children(mut a: EquihashNode, mut b: EquihashNode, trim: usize) -> EquihashNode {
    // XOR hashes after skipping first `trim` bytes
    let ha = a.hash.span();
    let hb = b.hash.span();
    let len_hash = a.hash.len();

    let mut hash = array![];
    let mut i: usize = trim;
    while i < len_hash {
        let byte: u8 = (*ha.at(i)) ^ (*hb.at(i));
        hash.append(byte);
        i = i + 1_usize;
    }

    // Concatenate indices; ordering decided by indices_before
    let ia = a.indices.span();
    let ib = b.indices.span();
    let len_a = a.indices.len();
    let len_b = b.indices.len();

    let mut indices = array![];

    if indices_before(@a, @b) {
        i = 0;
        while i < len_a {
            indices.append(*ia.at(i));
            i = i + 1_usize;
        }
        let mut j: usize = 0;
        while j < len_b {
            indices.append(*ib.at(j));
            j = j + 1_usize;
        }
    } else {
        i = 0;
        while i < len_b {
            indices.append(*ib.at(i));
            i = i + 1_usize;
        }
        let mut j: usize = 0;
        while j < len_a {
            indices.append(*ia.at(j));
            j = j + 1_usize;
        }
    }

    EquihashNode { hash, indices }
}

fn is_zero_prefix(node: EquihashNode, len: usize) -> bool {
    if node.hash.len() < len {
        return false;
    }
    let h = node.hash.span();
    let mut i: usize = 0;
    while i < len {
        if *h.at(i) != 0_u8 {
            return false;
        }
        i = i + 1_usize;
    }
    true
}

fn empty_node() -> EquihashNode {
    EquihashNode { hash: array![], indices: array![] }
}

// =====================
// U32-optimized node helpers (stores 20-bit elements as u32 instead of 3-byte sequences)
// This eliminates expand_array entirely for the blake2b cached path.
// =====================

/// Node optimized to store hash elements as u32 array (10 elements for Zcash n=200, k=9).
/// Each element is a 20-bit value stored in a u32.
/// This is more efficient than Array<u8> because:
/// 1. No expand_array byte-by-byte construction
/// 2. Collision checking compares u32s instead of 3 bytes
/// 3. XOR operations work on u32s instead of individual bytes
#[derive(Drop)]
struct OptimizedNodeU32 {
    hash: Array<u32>, // 10 elements, each storing a 20-bit value
    min_index: u32,
}

fn empty_optimized_node_u32() -> OptimizedNodeU32 {
    OptimizedNodeU32 { hash: array![], min_index: 0 }
}

/// Extract all 8 bytes from a u64 using sequential DivRem (more efficient than repeated shr64)
/// Returns (b0, b1, b2, b3, b4, b5, b6, b7) where b0 is least significant byte
#[cfg(feature: "blake2b")]
#[inline(always)]
fn extract_bytes_from_u64(w: u64) -> (u32, u32, u32, u32, u32, u32, u32, u32) {
    let (rest, b0) = DivRem::div_rem(w, 256);
    let (rest, b1) = DivRem::div_rem(rest, 256);
    let (rest, b2) = DivRem::div_rem(rest, 256);
    let (rest, b3) = DivRem::div_rem(rest, 256);
    let (rest, b4) = DivRem::div_rem(rest, 256);
    let (rest, b5) = DivRem::div_rem(rest, 256);
    let (b7, b6) = DivRem::div_rem(rest, 256);
    (
        b0.try_into().unwrap(),
        b1.try_into().unwrap(),
        b2.try_into().unwrap(),
        b3.try_into().unwrap(),
        b4.try_into().unwrap(),
        b5.try_into().unwrap(),
        b6.try_into().unwrap(),
        b7.try_into().unwrap(),
    )
}

/// Extract 10 u32 elements (20-bit each) directly from blake2b u64 state.
/// For Zcash (n=200, k=9): produces 10 elements from 25 bytes (200 bits).
#[cfg(feature: "blake2b")]
fn extract_elements_from_state_u32(
    state: Box<[u64; 8]>, subindex: u32,
) -> Array<u32> {
    let [w0, w1, w2, w3, w4, w5, w6, _w7] = state.unbox();

    if subindex == 0 {
        extract_elements_subindex0(w0, w1, w2, w3)
    } else {
        extract_elements_subindex1(w3, w4, w5, w6)
    }
}

/// Extract 10 elements from bytes 0-24 (subindex 0)
/// Bytes 0-7 in w0, 8-15 in w1, 16-23 in w2, 24 in w3[0]
#[cfg(feature: "blake2b")]
#[inline(always)]
fn extract_elements_subindex0(w0: u64, w1: u64, w2: u64, w3: u64) -> Array<u32> {
    // Extract all bytes from each word using sequential DivRem
    let (b0, b1, b2, b3, b4, b5, b6, b7) = extract_bytes_from_u64(w0);
    let (b8, b9, b10, b11, b12, b13, b14, b15) = extract_bytes_from_u64(w1);
    let (b16, b17, b18, b19, b20, b21, b22, b23) = extract_bytes_from_u64(w2);
    // Only need first byte from w3 for subindex 0
    let b24: u32 = (w3 & 0xFF).try_into().unwrap();

    // Chunk 0: bytes 0-4 -> elem0, elem1
    let elem0 = (b0 * 4096) + (b1 * 16) + (b2 / 16);
    let elem1 = ((b2 & 0x0f) * 65536) + (b3 * 256) + b4;

    // Chunk 1: bytes 5-9 -> elem2, elem3
    let elem2 = (b5 * 4096) + (b6 * 16) + (b7 / 16);
    let elem3 = ((b7 & 0x0f) * 65536) + (b8 * 256) + b9;

    // Chunk 2: bytes 10-14 -> elem4, elem5
    let elem4 = (b10 * 4096) + (b11 * 16) + (b12 / 16);
    let elem5 = ((b12 & 0x0f) * 65536) + (b13 * 256) + b14;

    // Chunk 3: bytes 15-19 -> elem6, elem7
    let elem6 = (b15 * 4096) + (b16 * 16) + (b17 / 16);
    let elem7 = ((b17 & 0x0f) * 65536) + (b18 * 256) + b19;

    // Chunk 4: bytes 20-24 -> elem8, elem9
    let elem8 = (b20 * 4096) + (b21 * 16) + (b22 / 16);
    let elem9 = ((b22 & 0x0f) * 65536) + (b23 * 256) + b24;

    array![elem0, elem1, elem2, elem3, elem4, elem5, elem6, elem7, elem8, elem9]
}

/// Extract 10 elements from bytes 25-49 (subindex 1)
/// Bytes 25-31 in w3[1-7], 32-39 in w4, 40-47 in w5, 48-49 in w6[0-1]
#[cfg(feature: "blake2b")]
#[inline(always)]
fn extract_elements_subindex1(w3: u64, w4: u64, w5: u64, w6: u64) -> Array<u32> {
    // Extract all bytes from each word using sequential DivRem
    // For w3, we skip byte 0 (already used in subindex0) and use bytes 1-7
    let (_w3_b0, b0, b1, b2, b3, b4, b5, b6) = extract_bytes_from_u64(w3);
    let (b7, b8, b9, b10, b11, b12, b13, b14) = extract_bytes_from_u64(w4);
    let (b15, b16, b17, b18, b19, b20, b21, b22) = extract_bytes_from_u64(w5);
    // Only need first 2 bytes from w6
    let (rest, b23_u64) = DivRem::div_rem(w6, 256);
    let (_, b24_u64) = DivRem::div_rem(rest, 256);
    let b23: u32 = b23_u64.try_into().unwrap();
    let b24: u32 = b24_u64.try_into().unwrap();

    // Chunk 0: bytes 25-29 (w3[1-5]) -> elem0, elem1
    let elem0 = (b0 * 4096) + (b1 * 16) + (b2 / 16);
    let elem1 = ((b2 & 0x0f) * 65536) + (b3 * 256) + b4;

    // Chunk 1: bytes 30-34 (w3[6,7], w4[0,1,2]) -> elem2, elem3
    let elem2 = (b5 * 4096) + (b6 * 16) + (b7 / 16);
    let elem3 = ((b7 & 0x0f) * 65536) + (b8 * 256) + b9;

    // Chunk 2: bytes 35-39 (w4[3,4,5,6,7]) -> elem4, elem5
    let elem4 = (b10 * 4096) + (b11 * 16) + (b12 / 16);
    let elem5 = ((b12 & 0x0f) * 65536) + (b13 * 256) + b14;

    // Chunk 3: bytes 40-44 (w5[0,1,2,3,4]) -> elem6, elem7
    let elem6 = (b15 * 4096) + (b16 * 16) + (b17 / 16);
    let elem7 = ((b17 & 0x0f) * 65536) + (b18 * 256) + b19;

    // Chunk 4: bytes 45-49 (w5[5,6,7], w6[0,1]) -> elem8, elem9
    let elem8 = (b20 * 4096) + (b21 * 16) + (b22 / 16);
    let elem9 = ((b22 & 0x0f) * 65536) + (b23 * 256) + b24;

    array![elem0, elem1, elem2, elem3, elem4, elem5, elem6, elem7, elem8, elem9]
}

/// Creates a leaf node using the cached base hasher, storing hash as u32 array.
/// This bypasses expand_array entirely by extracting u32 elements directly.
#[cfg(feature: "blake2b")]
fn make_leaf_cached_u32(
    base_hasher: @Blake2bHasher, n: u32, idx: u32,
) -> OptimizedNodeU32 {
    let indices_per: u32 = equihash_indices_per_hash_output(n);

    // Which Blake2b invocation and which chunk?
    let hash_input_index: u32 = idx / indices_per;
    let subindex: u32 = idx % indices_per;

    // Clone the base hasher and finalize with the index using optimized update_u32_le
    let mut hasher: Blake2bHasher = base_hasher.clone_state();
    hasher.update_u32_le(hash_input_index);

    // Get raw state and extract u32 elements directly
    let state = hasher.finalize();
    let elements = extract_elements_from_state_u32(state, subindex);

    OptimizedNodeU32 { hash: elements, min_index: idx }
}

/// Check collision on first element of two u32 nodes.
/// For Zcash (n=200, k=9), collision_bytes=3 corresponds to comparing
/// the first 20-bit element (stored as first u32).
#[inline]
fn has_collision_u32(ref a: OptimizedNodeU32, ref b: OptimizedNodeU32) -> bool {
    *a.hash.at(0) == *b.hash.at(0)
}

/// Check if a's min_index < b's min_index
#[inline]
fn indices_before_u32(a: @OptimizedNodeU32, b: @OptimizedNodeU32) -> bool {
    *a.min_index < *b.min_index
}

/// Merge two u32 nodes: XOR hash elements after trimming first element.
/// For Zcash, trim=collision_bytes=3 corresponds to skipping 1 element.
fn from_children_u32(
    mut a: OptimizedNodeU32, mut b: OptimizedNodeU32,
) -> OptimizedNodeU32 {
    let mut ha = a.hash.span();
    let mut hb = b.hash.span();

    // Skip first element (the collision element we just verified)
    ha.pop_front().unwrap();
    hb.pop_front().unwrap();

    // XOR remaining elements
    let mut hash: Array<u32> = array![];
    while let (Option::Some(ea), Option::Some(eb)) = (ha.pop_front(), hb.pop_front()) {
        hash.append(*ea ^ *eb);
    };

    let min_index = if a.min_index < b.min_index {
        a.min_index
    } else {
        b.min_index
    };

    OptimizedNodeU32 { hash, min_index }
}

/// Check if u32 node has zero first element.
/// For the root node, we need to check that the remaining element(s) are zero.
#[inline]
fn is_zero_root_u32(node: OptimizedNodeU32) -> bool {
    let mut h = node.hash.span();
    match h.pop_front() {
        Option::Some(elem) => *elem == 0_u32,
        Option::None => true, // Empty hash is considered zero
    }
}

/// Tree validator using u32-optimized nodes and first-block caching.
/// This is the most efficient path: no expand_array, u32 operations for collision/XOR.
#[cfg(feature: "blake2b")]
fn tree_validator_cached_u32(
    n: u32,
    k: u32,
    base_hasher: @Blake2bHasher,
    indices_span: Span<u32>,
    start: usize,
    end: usize,
) -> (bool, OptimizedNodeU32) {
    let count = end - start;

    if count == 0_usize {
        return (false, empty_optimized_node_u32());
    }

    if count == 1_usize {
        let idx: u32 = *indices_span.at(start);
        let leaf = make_leaf_cached_u32(base_hasher, n, idx);
        return (true, leaf);
    }

    // Fast path for leaf pairs (count == 2)
    if count == 2_usize {
        let idx_left: u32 = *indices_span.at(start);
        let idx_right: u32 = *indices_span.at(start + 1);

        // Quick indices_before check (fail fast)
        if idx_left > idx_right {
            return (false, empty_optimized_node_u32());
        }

        // Build leaves using cached hasher
        let mut left = make_leaf_cached_u32(base_hasher, n, idx_left);
        let mut right = make_leaf_cached_u32(base_hasher, n, idx_right);

        // Check collision (first u32 element must match)
        if !has_collision_u32(ref left, ref right) {
            return (false, left);
        }

        let parent = from_children_u32(left, right);
        return (true, parent);
    }

    let mid: usize = start + (count / 2_usize);

    let (ok_left, mut left_node) = tree_validator_cached_u32(
        n, k, base_hasher, indices_span, start, mid,
    );
    if !ok_left {
        return (false, left_node);
    }

    let (ok_right, mut right_node) = tree_validator_cached_u32(
        n, k, base_hasher, indices_span, mid, end,
    );
    if !ok_right {
        return (false, right_node);
    }

    // Validate subtrees
    if !has_collision_u32(ref left_node, ref right_node) {
        return (false, left_node);
    }
    if !indices_before_u32(@left_node, @right_node) {
        return (false, left_node);
    }

    let parent = from_children_u32(left_node, right_node);
    (true, parent)
}

fn make_leaf(n: u32, k: u32, header_span: Array<u8>, idx: u32) -> EquihashNode {
    // n/8-byte slice from BLAKE2b
    let hash_bytes: Span<u8> = equihash_hash_index(header_span, n, k, idx);

    // *** essential step: expand into (k+1) elements of collision_bit_length bits ***
    let bit_len: u32 = collision_bit_length(n, k);
    let expanded: Array<u8> = expand_array(hash_bytes, bit_len);

    let mut inds = array![];
    inds.append(idx);

    EquihashNode { hash: expanded, indices: inds }
}

// Recursive tree validator (like Rust tree_validator)
fn tree_validator(
    n: u32,
    k: u32,
    collision_bytes: usize,
    header: @Array<u8>,
    indices_span: Span<u32>,
    start: usize,
    end: usize,
) -> (bool, EquihashNode) {
    let count = end - start;

    if count == 0_usize {
        return (false, empty_node());
    }

    if count == 1_usize {
        let idx: u32 = *indices_span.at(start);
        let leaf = make_leaf(n, k, header.clone(), idx);
        return (true, leaf);
    }

    let mid: usize = start + (count / 2_usize);

    let (ok_left, mut left_node) = tree_validator(
        n, k, collision_bytes, header, indices_span, start, mid,
    );
    if !ok_left {
        return (false, left_node);
    }

    let (ok_right, mut right_node) = tree_validator(
        n, k, collision_bytes, header, indices_span, mid, end,
    );
    if !ok_right {
        return (false, right_node);
    }

    // validate_subtrees(p, a, b)
    if !has_collision(ref left_node, ref right_node, collision_bytes) {
        return (false, left_node);
    }
    if !indices_before(@left_node, @right_node) {
        return (false, left_node);
    }

    let parent = from_children(left_node, right_node, collision_bytes);
    (true, parent)
}

// =====================
// Bitstream helpers
// =====================

// Get bit `bit_index` from a big-endian bitstream in `bytes`.
//
// bit 0 = MSB of bytes[0]
// bit 1 = next bit, etc.
fn get_bit_be(bytes: Span<u8>, bit_index: usize) -> u8 {
    let byte_index: usize = bit_index / 8_usize;
    let bit_in_byte_rev: usize = bit_index % 8_usize; // 0..7 (0 = MSB)
    let shift: u32 = 7_usize - bit_in_byte_rev; // how many bits to shift right

    let b: u8 = *bytes.at(byte_index);
    let b_u16: u16 = b.into();

    // Divide by 2^shift  (equivalent to >> shift)
    let pow_shift: u16 = pow32(shift).try_into().unwrap();
    let shifted: u16 = b_u16 / pow_shift;

    // bit = shifted % 2
    let bit: u16 = shifted % 2_u16;

    bit.try_into().unwrap()
}

// =====================
// Minimal decoder
// =====================

// Expand an array of bytes into elements of size `bit_len` bits, each
// output as `width = ceil(bit_len/8)` big-endian bytes.
//
// This mirrors Zcash's minimal::expand_array(data, bit_len, 0).
fn expand_array(bytes: Span<u8>, bit_len: u32) -> Array<u8> {
    let mut out = array![];

    let width: u32 = (bit_len + 7_u32) / 8_u32;
    let width_usize: usize = width;
    let mask: u64 = shl64(1_u64, bit_len);

    let mut acc_value: u64 = 0_u64;
    let mut acc_bits: u32 = 0_u32;

    let mut i: usize = 0_usize;
    for b in bytes {
        let b_u64: u64 = (*b).into();

        // Shift in 8 bits
        acc_value = shl64(acc_value, 8_u32) | b_u64;
        acc_bits = acc_bits + 8_u32;

        // While we have at least one element
        while acc_bits >= bit_len {
            let shift: u32 = acc_bits - bit_len;
            let elem: u64 = shr64(acc_value, shift) % mask;

            acc_bits = acc_bits - bit_len;
            acc_value = if shift == 0_u32 {
                0_u64
            } else {
                acc_value % shl64(1_u64, shift)
            };

            // write element as `width` big-endian bytes
            let mut j: usize = width_usize;
            while j > 0_usize {
                j = j - 1_usize;
                let shift_bytes: u32 = j * 8_usize;
                let byte_u64: u64 = shr64(elem, shift_bytes) % 256_u64;
                let byte: u8 = byte_u64.try_into().unwrap();
                out.append(byte);
            }
        }

        i = i + 1_usize;
    }

    out
}


// =====================
// Indices-based validator
// =====================

/// Ensures that the solution indices are in the correct format:
pub fn is_valid_solution_format(indices: Span<u32>) -> bool {
    if indices.len() != EQUIHASH_INDICES_TOTAL {
        return false;
    }

    // Check that indices are in range [0, 2^21)
    for idx in indices {
        if *idx > EQUIHASH_INDICES_MAX {
            return false;
        }
    }

    true
}

// Prime modulus for permutation check: 2^64 - 59 (largest 64-bit prime)
const PERMUTATION_PRIME: u128 = 18446744073709551557_u128;
// Base for polynomial hash: prime > 2^21 (max index value)
const PERMUTATION_BASE: u128 = 2097169_u128;
// Offset added to challenge to ensure r > max index value (2^21)
// This guarantees r - idx_val never underflows
const CHALLENGE_OFFSET: u128 = 10000000000_u128;

/// Computes a deterministic Fiat-Shamir challenge from the indices.
/// This derives a "random" value r from the input data itself.
fn compute_permutation_challenge(mut indices: Span<u32>) -> u128 {
    let mut hash: u128 = 0;
    let mut power: u128 = 1;

    for idx in indices {
        let idx_val: u128 = (*idx).into();
        // idx_val < 2^21, power < 2^64, so product < 2^85 fits in u128
        // hash < 2^64, adding < 2^85 still fits in u128
        hash = (hash + idx_val * power) % PERMUTATION_PRIME;
        power = (power * PERMUTATION_BASE) % PERMUTATION_PRIME;
    }

    (hash + CHALLENGE_OFFSET) % PERMUTATION_PRIME
}

/// Verifies that sorted_hint is a permutation of indices using the product check.
/// Based on Schwartz-Zippel lemma: if ∏(r - indices[i]) == ∏(r - sorted_hint[i])
/// for a random r, then the multisets are equal with overwhelming probability.
fn verify_permutation(mut indices: Span<u32>, mut sorted_hint: Span<u32>, r: u128) -> bool {
    let mut prod_indices: u128 = 1;
    let mut prod_sorted: u128 = 1;

    for idx in indices {
        let idx_val: u128 = (*idx).into();
        let sorted_val: u128 = (*sorted_hint.pop_front().unwrap()).into();

        // r >= CHALLENGE_OFFSET > 2^21 > max_index, so r > idx_val always
        let diff_idx = r - idx_val;
        let diff_sorted = r - sorted_val;

        prod_indices = (prod_indices * diff_idx) % PERMUTATION_PRIME;
        prod_sorted = (prod_sorted * diff_sorted) % PERMUTATION_PRIME;
    }

    prod_indices == prod_sorted
}

/// Verifies that the span is strictly increasing (each element > previous).
/// Uses pop_front for efficiency.
fn is_strictly_increasing(mut span: Span<u32>) -> bool {
    // Get first element, empty span is trivially increasing
    let first = span.pop_front();
    if first.is_none() {
        return true;
    }
    let mut prev = *first.unwrap();

    for idx in span {
        if prev >= *idx {
            return false;
        }
        prev = *idx;
    }
    true
}

/// Verifies that all indices are unique using a sorted hint.
///
/// This is an O(n) algorithm that leverages the prover/verifier paradigm:
/// - The prover provides a `sorted_indices_hint` containing the same indices but sorted
/// - The verifier checks:
///   1. The hint is strictly increasing (guarantees all hint values are unique)
///   2. The hint is a permutation of the original indices (via product check)
///
/// If both conditions hold, the original indices must all be unique.
///
/// # Arguments
/// * `indices` - The original Equihash solution indices (512 values)
/// * `sorted_indices_hint` - Hint from prover: same indices but sorted ascending
///
/// # Returns
/// * `true` if all indices are unique, `false` otherwise
pub fn is_unique_indices(indices: Span<u32>, sorted_indices_hint: Span<u32>) -> bool {
    let len = indices.len();

    // Length check: hint must have same length as indices
    if sorted_indices_hint.len() != len {
        return false;
    }

    // Trivial cases: empty or single element is always unique
    if len <= 1 {
        return true;
    }

    // Step 1: Verify sorted_indices_hint is strictly increasing
    // This guarantees all values in the hint are unique
    if !is_strictly_increasing(sorted_indices_hint) {
        return false;
    }

    // Step 2: Verify sorted_indices_hint is a permutation of indices
    // Using Schwartz-Zippel product check with Fiat-Shamir challenge
    let r = compute_permutation_challenge(indices);
    verify_permutation(indices, sorted_indices_hint, r)
}

// For each block, all 512 leaf hashes share the same:
//   - Personalization ("ZcashPoW" + n + k)
//   - Hash length (50 bytes for Zcash n=200, k=9)
//   - Common input prefix (header = 140 bytes)
//
// By pre-computing a "base hasher" with these common elements, we:
//   1. Compute the initial state (IV XOR params) only once
//   2. Process the first 128 bytes (first compression block) only once
//   3. For each leaf, clone the hasher and only process the remaining 12 bytes + 4-byte index
fn build_equihash_header_bytes(
    header: @Header, prev_block_hash: Digest, txid_root: Digest,
) -> Array<u8> {
    let mut bytes: Array<u8> = array![];

    append_u32_le(ref bytes, *header.version);
    append_digest(ref bytes, prev_block_hash);
    append_digest(ref bytes, txid_root);
    append_digest(ref bytes, *header.final_sapling_root);
    append_u32_le(ref bytes, *header.time);
    append_u32_le(ref bytes, *header.bits);
    append_digest(ref bytes, *header.nonce);

    bytes
}

/// Builds a base hasher pre-configured for Equihash with the full 140-byte header.
/// The header is: version(4) + prev_block_hash(32) + txid_root(32) + final_sapling_root(32)
///                + time(4) + bits(4) + nonce(32) = 140 bytes
///
/// Clone this hasher for each leaf hash, then update with just the 4-byte index.
#[cfg(feature: "blake2b")]
fn build_equihash_base_hasher(
    header: @Header, prev_block_hash: Digest, txid_root: Digest,
) -> Blake2bHasher {
    // Create hasher with precomputed Equihash parameters (n=200, k=9)
    let mut hasher = Blake2bParamsTrait::new()
        .hash_length(EQUIHASH_HASH_OUTPUT_LENGTH)
        .personal(EQUIHASH_PERSONALIZATION)
        .to_state();

    // Build the 140-byte header and process it
    // This compresses the first block (128 bytes) and buffers the remaining 12 bytes
    let header_bytes = build_equihash_header_bytes(header, prev_block_hash, txid_root);
    hasher.update_span(header_bytes.span());

    hasher
}

/// Wagner tree validator using u32-optimized nodes and first-block caching.
/// This validates the Equihash solution by building the collision tree and verifying
/// that all collisions are valid and the root hash is zero.
#[cfg(feature: "blake2b")]
pub fn wagner_tree_validator(
    header: @Header, prev_block_hash: Digest, txid_root: Digest,
) -> Result<(), ByteArray> {
    let base_hasher = build_equihash_base_hasher(header, prev_block_hash, txid_root);
    let indices_span = (*header.indices);

    // Use u32-optimized tree validator (no expand_array, u32 operations)
    let (ok, root) = tree_validator_cached_u32(
        EQUIHASH_N, EQUIHASH_K, @base_hasher, indices_span, 0_usize, indices_span.len(),
    );
    if !ok {
        return Result::Err(format!("[equihash] tree validation failed"));
    }

    // Root hash must be zero (single u32 element remaining after k=9 merges)
    if !is_zero_root_u32(root) {
        return Result::Err(format!("[equihash] root hash is not zero"));
    }

    Result::Ok(())
}

/// Fallback wagner_tree_validator when blake2b feature is not enabled.
/// Uses the non-cached path with expand_array.
#[cfg(not(feature: "blake2b"))]
pub fn wagner_tree_validator(
    header: @Header, prev_block_hash: Digest, txid_root: Digest,
) -> Result<(), ByteArray> {
    // Build the 140-byte header for Equihash
    let header_bytes = build_equihash_header_bytes(header, prev_block_hash, txid_root);
    let indices_span = (*header.indices);
    let collision_bytes: usize = collision_byte_length(EQUIHASH_N, EQUIHASH_K);

    // Use the non-cached tree validator
    let (ok, root) = tree_validator(
        EQUIHASH_N,
        EQUIHASH_K,
        collision_bytes,
        @header_bytes,
        indices_span,
        0_usize,
        indices_span.len(),
    );
    if !ok {
        return Result::Err(format!("[equihash] tree validation failed"));
    }

    // Root hash must have zero prefix
    if !is_zero_prefix(root, collision_bytes) {
        return Result::Err(format!("[equihash] root hash is not zero"));
    }

    Result::Ok(())
}

pub fn is_valid_solution_indices(
    n: u32, k: u32, input: Array<u8>, nonce: Array<u8>, indices: Array<u32>,
) -> bool {
    // Same param checks as above
    if n % 8_u32 != 0_u32 {
        return false;
    }
    if k < 3_u32 {
        return false;
    }
    if k >= n {
        return false;
    }
    let k1 = k + 1_u32;
    if n % k1 != 0_u32 {
        return false;
    }

    // must be exactly 2^k indices
    let expected_u32: u32 = pow32(k).try_into().unwrap();
    let expected_len: usize = expected_u32;
    if indices.len() != expected_len {
        return false;
    }

    // header_plus_nonce = input || nonce
    let mut header = input;
    let nonce_span = nonce.span();
    let mut i: usize = 0;
    while i < nonce.len() {
        header.append(*nonce_span.at(i));
        i = i + 1_usize;
    }

    let indices_span = indices.span();
    let collision_bytes: usize = collision_byte_length(n, k);

    let (ok, root) = tree_validator(
        n, k, collision_bytes, @header, indices_span, 0_usize, indices.len(),
    );
    if !ok {
        return false;
    }

    // Root hash must have zero prefix of length collision_byte_length()
    is_zero_prefix(root, collision_bytes)
}

// =====================
// Public API: header-level helpers
// =====================

/// Builds the Equihash input (block header without nonce & solution), converts the
/// nonce into byte array, and runs the recursive Equihash validator with indices directly.
///
/// # Arguments
/// * `header` - The block header containing the Equihash solution indices
/// * `prev_block_hash` - Hash of the previous block
/// * `txid_root` - Merkle root of transactions
/// * `sorted_indices_hint` - Prover hint: the same indices sorted ascending (for O(n) uniqueness check)
pub fn check_equihash_solution(
    header: Header, prev_block_hash: Digest, txid_root: Digest, sorted_indices_hint: Span<u32>,
) -> Result<(), ByteArray> {
    if !is_valid_solution_format(header.indices) {
        return Result::Err(format!("[equihash] invalid solution format"));
    }

    if !is_unique_indices(header.indices, sorted_indices_hint) {
        return Result::Err(format!("[equihash] duplicate indices in solution"));
    }

    match wagner_tree_validator(@header, prev_block_hash, txid_root) {
        Result::Ok(()) => Result::Ok(()),
        Result::Err(e) => Result::Err(e),
    }
}

// =====================
// Header serialization helpers
// =====================

fn build_equihash_input(header: @Header, prev_block_hash: Digest, txid_root: Digest) -> Array<u8> {
    let mut bytes: Array<u8> = array![];
    append_u32_le(ref bytes, *header.version);
    append_digest(ref bytes, prev_block_hash);
    append_digest(ref bytes, txid_root);
    append_digest(ref bytes, *header.final_sapling_root);
    append_u32_le(ref bytes, *header.time);
    append_u32_le(ref bytes, *header.bits);
    bytes
}

fn digest_to_le_bytes(digest: Digest) -> Array<u8> {
    let mut bytes: Array<u8> = array![];
    append_digest(ref bytes, digest);
    bytes
}

fn append_digest(ref bytes: Array<u8>, digest: Digest) {
    for word in digest.value.span() {
        append_u32_be(ref bytes, *word);
    }
}

fn append_u32_be(ref bytes: Array<u8>, value: u32) {
    bytes.append((value / pow32(24_u32).try_into().unwrap()).try_into().unwrap());
    bytes.append((value / pow32(16_u32).try_into().unwrap() % 256_u32).try_into().unwrap());
    bytes
        .append(
            (value / pow32(8_u32).try_into().unwrap() % pow32(8_u32).try_into().unwrap())
                .try_into()
                .unwrap(),
        );
    bytes.append((value % 256_u32).try_into().unwrap());
}
fn append_u32_le(ref bytes: Array<u8>, value: u32) {
    let mut tmp: u64 = value.into();
    let mut i: usize = 0;
    while i < 4_usize {
        let byte = (tmp % 256_u64).try_into().unwrap();
        bytes.append(byte);
        tmp = tmp / 256_u64;
        i = i + 1_usize;
    }
}

