// =======================
// Equihash helpers on top of our Blake2b
// =======================

use consensus::params::{EQUIHASH_INDICES_TOTAL, EQUIHASH_INDICES_MAX};
use consensus::types::block::Header;
use core::array::ArrayTrait;
use core::traits::{Into, TryInto};
use utils::bit_shifts::{pow32, shl64, shr64};
use utils::blake2b::blake2b_hash;
use utils::hash::Digest;


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

fn distinct_indices(a: @EquihashNode, b: @EquihashNode) -> bool {
    for ai in a.indices.span() {
        for bi in b.indices.span() {
            if ai == bi {
                return false;
            }
        }
    }
    true
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
    if !distinct_indices(@left_node, @right_node) {
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

/// Mirrors `CheckEquihashSolution` from `src/pow/pow.cpp` in zcashd.
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
    // let input = build_equihash_input(header, prev_block_hash, txid_root);
    // let nonce_bytes = digest_to_le_bytes(*header.nonce);

    // if (*header.indices).len() != EQUIHASH_INDICES_TOTAL {
    //     return Result::Err(
    //         format!(
    //             "[equihash] invalid indices count: expected {}, got {}",
    //             expected_indices,
    //             (*header.indices).len(),
    //         ),
    //     );
    // }
    if !is_valid_solution_format(header.indices) {
        return Result::Err(format!("[equihash] invalid solution format"));
    }

    if !is_unique_indices(header.indices, sorted_indices_hint) {
        return Result::Err(format!("[equihash] duplicate indices in solution"));
    }

    // if is_valid_solution_indices(EQUIHASH_N, EQUIHASH_K, input, nonce_bytes, indices) {
    //     Result::Ok(())
    // } else {
    //     Result::Err(format!("[equihash] invalid solution"))
    // }
    Result::Ok(())
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

