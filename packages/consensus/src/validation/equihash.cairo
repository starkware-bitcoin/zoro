// =======================
// Equihash helpers on top of our Blake2b
// =======================

use consensus::params::{EQUIHASH_K, EQUIHASH_N, EQUIHASH_SOLUTION_SIZE_BYTES};
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

// Decode minimal-encoded solution bytes into indices,
// like Rust `indices_from_minimal(p, soln)`.
// Returns (ok, indices).
fn indices_from_minimal_bytes(n: u32, k: u32, minimal: Array<u8>) -> (bool, Array<u32>) {
    // Basic param checks (same as Params::new)
    if n % 8_u32 != 0_u32 {
        return (false, array![]);
    }
    if k < 3_u32 {
        return (false, array![]);
    }
    if k >= n {
        return (false, array![]);
    }
    let k1 = k + 1_u32;
    if n % k1 != 0_u32 {
        return (false, array![]);
    }

    let c_bits: u32 = collision_bit_length(n, k);
    let bits_per_index: u32 = c_bits + 1_u32;

    // expected length in bytes = (2^k * (c_bits+1))/8
    let count_u32: u32 = pow32(k).try_into().unwrap();
    let numerator_bits: u64 = (count_u32.into()) * (bits_per_index.into());
    let expected_len_u32: u32 = (numerator_bits / 8_u64).try_into().unwrap();
    let minimal_len: usize = minimal.len();

    if minimal_len != expected_len_u32 {
        return (false, array![]);
    }

    let indices_len: usize = count_u32;
    let span = minimal.span();
    let total_bits: usize = minimal_len * 8_usize;
    let needed_bits: usize = count_u32 * bits_per_index;

    if total_bits < needed_bits {
        return (false, array![]);
    }

    let mut indices = array![];
    let mut idx: usize = 0;
    while idx < indices_len {
        let mut value_u32: u32 = 0_u32;

        let mut b: u32 = 0_u32;
        while b < bits_per_index {
            let global_bit_u64: u64 = idx.into() * bits_per_index.into() + b.into();
            let global_bit: usize = global_bit_u64.try_into().unwrap();

            let bit_val: u8 = get_bit_be(span, global_bit);
            // value = (value << 1) | bit  (no <<)
            value_u32 = value_u32 * 2_u32 + (bit_val.into());

            b = b + 1_u32;
        }

        indices.append(value_u32);
        idx = idx + 1_usize;
    }

    (true, indices)
}
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
/// nonce and solution into byte arrays, and runs the recursive Equihash validator.
pub fn check_equihash_solution(
    header: @Header, prev_block_hash: Digest, txid_root: Digest,
) -> Result<(), ByteArray> {
    let input = build_equihash_input(header, prev_block_hash, txid_root);
    let nonce_bytes = digest_to_le_bytes(*header.nonce);
    let solution_bytes = solution_words_to_bytes(*header.solution);

    if solution_bytes.len() != EQUIHASH_SOLUTION_SIZE_BYTES {
        return Result::Err(
            format!(
                "[equihash] invalid solution length: expected {} bytes, got {}",
                EQUIHASH_SOLUTION_SIZE_BYTES,
                solution_bytes.len(),
            ),
        );
    }

    if is_valid_solution(EQUIHASH_N, EQUIHASH_K, input, nonce_bytes, solution_bytes) {
        Result::Ok(())
    } else {
        Result::Err(format!("[equihash] invalid solution"))
    }
}

/// Cairo version of Rust:
/// pub fn is_valid_solution(n, k, input, nonce, soln_bytes) -> Result<(), Error>
/// Here we just return `bool`.
pub fn is_valid_solution(
    n: u32, k: u32, input: Array<u8>, nonce: Array<u8>, soln: Array<u8>,
) -> bool {
    // Decode minimal-encoded solution bytes -> indices
    let (ok_indices, indices) = indices_from_minimal_bytes(n, k, soln);
    if !ok_indices {
        return false;
    }

    // Recursive validation (like Rust is_valid_solution_recursive)
    is_valid_solution_indices(n, k, input, nonce, indices)
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

fn solution_words_to_bytes(solution: Span<u32>) -> Array<u8> {
    let mut bytes: Array<u8> = array![];
    for word in solution {
        append_u32_le(ref bytes, *word);
    }
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

