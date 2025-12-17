// Minimal Blake2b (unkeyed) with personalization and variable digest length.
// Intended to match what librustzcash uses for Equihash verification:
//   personalization = b"ZcashPoW" ++ n_le (u32) ++ k_le (u32)
//   outlen = indices_per_hash_output(n) * (n / 8)
//
// Constraints respected:
// - No indexing or mutation of fixed-size arrays ([T; N])
// - No mutation of Array<T> cells; only create new Arrays with append
// - No bitshift operators (<<, >>); uses Pow + DivRem instead.

use core::array::ArrayTrait;
#[cfg(feature: "blake2b")]
use core::blake::{Blake2bHasherTrait, Blake2bParamsTrait};
use core::num::traits::WrappingAdd;
use core::traits::{Into, TryInto};
use crate::bit_shifts::{shl64, shr64};

pub type Blake2bDigest = Array<u8>;

const BLAKE2B_BLOCKBYTES: usize = 128;
const BLAKE2B_OUTBYTES: usize = 64;
const ROUNDS: usize = 12;


#[derive(Copy, Drop)]
struct Blake2bParams {
    outlen: u32,
    personal: [u8; 16],
}

// Blake2b internal state.
#[derive(Drop)]
struct Blake2bState {
    h: Array<u64>, // chaining value (8 words)
    t0: u64, // low 64 bits of byte counter
    t1: u64, // high 64 bits of byte counter (unused in short messages)
    f0: u64, // finalization flag (unused explicitly)
    f1: u64, // unused in this minimal implementation
    buf: Array<u8>, // current block buffer (length BLAKE2B_BLOCKBYTES)
    buflen: u32, // how many bytes currently in buf
    outlen: u32 // desired output length
}


fn rotr64(x: u64, n: u32) -> u64 {
    // rotate-right 64 bits
    shr64(x, n) | shl64(x, 64_u32 - n)
}

// Convert constant IV into a dynamic Array<u64>.
fn iv() -> Array<u64> {
    array![
        0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
        0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179,
    ]
}

// σ (sigma) permutation rows for Blake2b.
// Each call returns an Array<usize> of length 16 (read-only).
fn sigma(round: usize) -> Array<usize> {
    match round % 10 {
        0 => array![0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        1 => array![14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        2 => array![11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        3 => array![7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        4 => array![9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        5 => array![2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        6 => array![12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        7 => array![13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        8 => array![6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        _ => array![10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    }
}

// Load little-endian u64 from a byte span at offset `off`.
fn load_le_u64(mut bytes: Span<u8>, off: usize) -> u64 {
    let mut bytes = bytes.slice(off, 8);

    shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 0)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 8)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 16)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 24)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 32)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 40)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 48)
        + shl64(Into::<u8, u64>::into(*bytes.pop_front().unwrap()), 56)
}

// Build parameter block (64 bytes) as an Array<u8>.
// Layout matches the Blake2b spec.
fn build_param_block(p: Blake2bParams) -> Array<u8> {
    // 0: digest length
    // 1: key length (0 in our case)
    // 2: fanout (1)
    // 3: depth (1)
    // 4..7: leaf length (0)
    // 8..15: node offset (0)
    // 16: node depth (0)
    // 17: inner length (0)
    // 18..31: reserved (zero)
    // 32..47: salt (zero)
    let mut b = array![
        p.outlen.try_into().unwrap(), 0_u8, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ];

    // 48..63: personal (16 bytes)
    for byte in p.personal.span() {
        b.append(*byte);
    }

    b
}

// Helper: create a zeroed buffer of len BLAKE2B_BLOCKBYTES.
fn make_zero_buf() -> Array<u8> {
    array![
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0,
    ]
}

// Initialize Blake2bState with given outlen and personalization.
fn blake2b_init(outlen: u32, personalization: [u8; 16]) -> Blake2bState {
    let params = Blake2bParams { outlen, personal: personalization };
    let param_bytes = build_param_block(params); // Array<u8>

    let ivv = iv(); // Array<u64> (8 words)
    let mut iv_span = ivv.span();
    let pb_span = param_bytes.span();

    // h[i] = IV[i] ^ LE_64(param_bytes[8*i .. 8*i+8])
    let mut h = array![];
    let mut i: usize = 0;
    while i < 8 {
        let mut w: u64 = 0_u64;
        let mut j: usize = 0;
        while j < 8 {
            let b: u8 = *pb_span.at(8 * i + j);
            let shift: u32 = 8_u32 * j;
            w = w + shl64(Into::<u8, u64>::into(b), shift);
            j = j + 1_usize;
        }
        let iv_word: u64 = *iv_span.pop_front().unwrap();
        h.append(iv_word ^ w);
        i = i + 1_usize;
    }

    Blake2bState {
        h, t0: 0_u64, t1: 0_u64, f0: 0_u64, f1: 0_u64, buf: make_zero_buf(), buflen: 0_u32, outlen,
    }
}

// Functional update: return a new Array<u64> with index `idx` set to `val`.
fn array_u64_update_one(orig: Array<u64>, idx: usize, val: u64) -> Array<u64> {
    let mut out = array![];
    for (i, old) in orig.into_iter().enumerate() {
        let new_v = if i == idx {
            val
        } else {
            old
        };
        out.append(new_v);
    }
    out
}


// G mixing function on v-array, using indices a,b,c,d and message words x,y.
// v is Array<u64>; we DO NOT mutate, we return a new Array<u64>.
fn g(va: u64, vb: u64, vc: u64, vd: u64, x: u64, y: u64) -> (u64, u64, u64, u64) {
    let t0 = va.wrapping_add(vb).wrapping_add(x);
    let t1 = rotr64(vd ^ t0, 32_u32);
    let t2 = vc.wrapping_add(t1);
    let t3 = rotr64(vb ^ t2, 24_u32);
    let t4 = t0.wrapping_add(t3).wrapping_add(y);
    let t5 = rotr64(t1 ^ t4, 16_u32);
    let t6 = t2.wrapping_add(t5);
    let t7 = rotr64(t3 ^ t6, 63_u32);

    (t4, t7, t6, t5)
}

// Compression function F(state, block, is_last).
// Does not mutate any arrays in place; builds new Arrays and reassigns fields.
fn compress(ref state: Blake2bState, block: Array<u8>, is_last: bool) {
    // m[0..16] from block
    let mut m = array![];
    let mut j: usize = 0;
    let b_span = block.span();
    while j < 16 {
        let word = load_le_u64(b_span, j * 8);
        m.append(word);
        j = j + 1_usize;
    }

    let ivv = iv();
    // v = h[0..8] ++ IV[0..8]
    let mut v0 = *state.h[0];
    let mut v1 = *state.h[1];
    let mut v2 = *state.h[2];
    let mut v3 = *state.h[3];
    let mut v4 = *state.h[4];
    let mut v5 = *state.h[5];
    let mut v6 = *state.h[6];
    let mut v7 = *state.h[7];
    let mut v8 = *ivv[0];
    let mut v9 = *ivv[1];
    let mut v10 = *ivv[2];
    let mut v11 = *ivv[3];
    let mut v12 = *ivv[4];
    let mut v13 = *ivv[5];
    let mut v14 = *ivv[6];
    let mut v15 = *ivv[7];

    // fold t and f into v12, v13, v14 (no arrays)
    v12 = v12 ^ state.t0;
    v13 = v13 ^ state.t1;
    if is_last {
        v14 = v14 ^ 0xFFFFFFFFFFFFFFFF_u128.try_into().unwrap();
    }

    let mut r: usize = 0;
    let m_span = m.span();
    while r < ROUNDS {
        let s = sigma(r);
        let mut s_span = s.span();

        // Column rounds
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv0, nv4, nv8, nv12) = g(v0, v4, v8, v12, *m_span.at(i0), *m_span.at(i1));
            v0 = nv0;
            v4 = nv4;
            v8 = nv8;
            v12 = nv12;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv1, nv5, nv9, nv13) = g(v1, v5, v9, v13, *m_span.at(i0), *m_span.at(i1));
            v1 = nv1;
            v5 = nv5;
            v9 = nv9;
            v13 = nv13;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv2, nv6, nv10, nv14) = g(v2, v6, v10, v14, *m_span.at(i0), *m_span.at(i1));
            v2 = nv2;
            v6 = nv6;
            v10 = nv10;
            v14 = nv14;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv3, nv7, nv11, nv15) = g(v3, v7, v11, v15, *m_span.at(i0), *m_span.at(i1));
            v3 = nv3;
            v7 = nv7;
            v11 = nv11;
            v15 = nv15;
        }

        // Diagonal rounds
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv0, nv5, nv10, nv15) = g(v0, v5, v10, v15, *m_span.at(i0), *m_span.at(i1));
            v0 = nv0;
            v5 = nv5;
            v10 = nv10;
            v15 = nv15;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv1, nv6, nv11, nv12) = g(v1, v6, v11, v12, *m_span.at(i0), *m_span.at(i1));
            v1 = nv1;
            v6 = nv6;
            v11 = nv11;
            v12 = nv12;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv2, nv7, nv8, nv13) = g(v2, v7, v8, v13, *m_span.at(i0), *m_span.at(i1));
            v2 = nv2;
            v7 = nv7;
            v8 = nv8;
            v13 = nv13;
        }
        {
            let i0 = *s_span.pop_front().unwrap();
            let i1 = *s_span.pop_front().unwrap();
            let (nv3, nv4, nv9, nv14) = g(v3, v4, v9, v14, *m_span.at(i0), *m_span.at(i1));
            v3 = nv3;
            v4 = nv4;
            v9 = nv9;
            v14 = nv14;
        }

        r = r + 1_usize;
    }

    let mut new_h = array![
        *state.h[0] ^ v0 ^ v8, *state.h[1] ^ v1 ^ v9, *state.h[2] ^ v2 ^ v10,
        *state.h[3] ^ v3 ^ v11, *state.h[4] ^ v4 ^ v12, *state.h[5] ^ v5 ^ v13,
        *state.h[6] ^ v6 ^ v14, *state.h[7] ^ v7 ^ v15,
    ];

    state.h = new_h;
}

// Update function: absorb arbitrary-length input into the state.
// All "buffer" modifications are functional: we build a new Array<u8>.
fn blake2b_update(ref state: Blake2bState, input: Array<u8>) {
    let mut in_off: usize = 0;
    let in_len: usize = input.len();
    let in_span = input.span();

    // If buffer already has data, fill it first.
    if state.buflen != 0_u32 {
        let filled: usize = state.buflen;
        let take: usize = core::cmp::min(in_len - in_off, BLAKE2B_BLOCKBYTES - filled);

        // new_buf = old_buf[0..B] extended with input bytes where needed
        let mut old_span = state.buf.span();
        let mut new_buf = array![];
        for idx in (0..BLAKE2B_BLOCKBYTES) {
            let v = if idx < filled {
                *old_span.pop_front().unwrap()
            } else if idx < filled + take {
                *in_span.at(in_off + (idx - filled))
            } else {
                0_u8
            };
            new_buf.append(v);
        }

        state.buf = new_buf;
        state.buflen = filled + take;
        in_off = in_off + take;

        if state.buflen == BLAKE2B_BLOCKBYTES {
            state.t0 = state.t0 + BLAKE2B_BLOCKBYTES.into();
            // compress full buffer
            let mut block = array![];
            let buf_span2 = state.buf.span().slice(0, 128);
            block.append_span(buf_span2);
            compress(ref state, block, false);
            state.buf = make_zero_buf();
            state.buflen = 0_u32;
        }
    }

    // Process full blocks directly from input.
    while in_len - in_off > BLAKE2B_BLOCKBYTES {
        state.t0 = state.t0 + BLAKE2B_BLOCKBYTES.into();

        let mut block = array![];

        block.append_span(in_span.slice(in_off, BLAKE2B_BLOCKBYTES));

        compress(ref state, block, false);
        in_off = in_off + BLAKE2B_BLOCKBYTES;
    }

    // Buffer tail
    let tail: usize = in_len - in_off;
    let mut new_buf_tail = array![];
    let mut i_tail: usize = 0;
    while i_tail < BLAKE2B_BLOCKBYTES {
        let v = if i_tail < tail {
            *in_span.at(in_off + i_tail)
        } else {
            0_u8
        };
        new_buf_tail.append(v);
        i_tail = i_tail + 1_usize;
    }
    state.buf = new_buf_tail;
    state.buflen = tail;
}

// Finalize and return the digest (outlen bytes).
fn blake2b_finalize(ref state: Blake2bState) -> Array<u8> {
    // last block flag set
    state.t0 = state.t0 + state.buflen.into();

    // build last block from buf (already zero-padded beyond buflen)
    let buf_span = state.buf.span();
    let mut block = array![];

    let mut i: usize = 0;
    while i < BLAKE2B_BLOCKBYTES {
        block.append(*buf_span.at(i));
        i = i + 1_usize;
    }

    compress(ref state, block, true);

    // output buffer: little-endian words of h, truncated to outlen
    let mut out = array![];
    let mut h_span = state.h.span();
    let mut word_idx: usize = 0;
    let mut stop: bool = false;

    while word_idx < 8_usize && !stop {
        let word: u64 = *h_span.pop_front().unwrap();

        let mut k: usize = 0;
        while k < 8_usize && !stop {
            if out.len() >= state.outlen {
                stop = true;
                break;
            }

            // least-significant byte first: word >> (8*k)
            let shift: u32 = (8_u32 * k);
            let byte_u64: u64 = shr64(word, shift);
            let byte: u8 = (byte_u64 % 256_u64).try_into().unwrap();
            out.append(byte);

            k = k + 1_usize;
        }

        word_idx = word_idx + 1_usize;
    }

    out
}

// Convenience one-shot hash ( Cairo1 implementation ).
// Used when neither blake2b nor blake2b_mock features are enabled.
#[cfg(not(feature: "blake2b"))]
#[cfg(not(feature: "blake2b_mock"))]
pub fn blake2b_hash(input: Array<u8>, outlen: u32, personalization: [u8; 16]) -> Blake2bDigest {
    let mut st = blake2b_init(outlen, personalization);

    blake2b_update(ref st, input);

    blake2b_finalize(ref st)
}

// Convenience one-shot hash ( Mock implementation - returns zeros ).
// Used when blake2b_mock feature is enabled.
#[cfg(feature: "blake2b_mock")]
pub fn blake2b_hash(_input: Array<u8>, outlen: u32, _personalization: [u8; 16]) -> Blake2bDigest {
    let mut out: Array<u8> = array![];
    let mut i: u32 = 0;
    while i < outlen {
        out.append(0_u8);
        i += 1;
    }
    out
}

// Convenience one-shot hash ( Opcode implementation ).
// Used when blake2b feature is enabled (and blake2b_mock is NOT enabled).
#[cfg(feature: "blake2b")]
#[cfg(not(feature: "blake2b_mock"))]
pub fn blake2b_hash(input: Array<u8>, outlen: u32, personalization: [u8; 16]) -> Blake2bDigest {
    // Convert personalization [u8; 16] to [u64; 2] (little-endian)
    let personal_u64 = personalization_to_u64_pair(personalization);

    // Create hasher with parameters
    let mut hasher = Blake2bParamsTrait::new()
        .hash_length(outlen.try_into().unwrap())
        .personal(personal_u64)
        .to_state();

    // Process input
    hasher.update(input);

    // Finalize and get state (Box<[u64; 8]>)
    let state = hasher.finalize();

    // Convert state [u64; 8] to bytes, truncated to outlen
    state_to_bytes(state.unbox(), outlen)
}

/// Convert a 16-byte personalization array to two little-endian u64 words.
pub fn personalization_to_u64_pair(personal: [u8; 16]) -> [u64; 2] {
    let [b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15] = personal;

    let word0: u64 = b0.into()
        + shl64(b1.into(), 8)
        + shl64(b2.into(), 16)
        + shl64(b3.into(), 24)
        + shl64(b4.into(), 32)
        + shl64(b5.into(), 40)
        + shl64(b6.into(), 48)
        + shl64(b7.into(), 56);

    let word1: u64 = b8.into()
        + shl64(b9.into(), 8)
        + shl64(b10.into(), 16)
        + shl64(b11.into(), 24)
        + shl64(b12.into(), 32)
        + shl64(b13.into(), 40)
        + shl64(b14.into(), 48)
        + shl64(b15.into(), 56);

    [word0, word1]
}

/// Convert a u64 word to little-endian bytes, appending up to `count` bytes.
fn append_u64_le_bytes(ref out: Array<u8>, word: u64, count: u32) {
    let mut remaining = word;
    let mut i: u32 = 0;
    while i < count {
        out.append((remaining % 256).try_into().unwrap());
        remaining = remaining / 256;
        i += 1;
    };
}

/// Convert Blake2b state (8 x u64 words) to a byte array, truncated to outlen bytes.
pub fn state_to_bytes(state: [u64; 8], outlen: u32) -> Array<u8> {
    let [w0, w1, w2, w3, w4, w5, w6, w7] = state;
    let words: [u64; 8] = [w0, w1, w2, w3, w4, w5, w6, w7];

    let mut out: Array<u8> = array![];
    let mut remaining = outlen;

    for word in words.span() {
        if remaining == 0 {
            break;
        }
        let count = if remaining >= 8 {
            8
        } else {
            remaining
        };
        append_u64_le_bytes(ref out, *word, count);
        remaining -= count;
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_blake2b_empty_64() {
        let input = array![];
        let outlen = 64_u32;
        let personalization = [
            0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ];

        let hash = blake2b_hash(input, outlen, personalization);
        let span = hash.span();

        let expected: [u8; 64] = [
            120, 106, 2, 247, 66, 1, 89, 3, 198, 198, 253, 133, 37, 82, 210, 114, 145, 47, 71, 64,
            225, 88, 71, 97, 138, 134, 226, 23, 247, 31, 84, 25, 210, 94, 16, 49, 175, 238, 88, 83,
            19, 137, 100, 68, 147, 78, 176, 75, 144, 58, 104, 91, 20, 72, 183, 85, 213, 111, 112,
            26, 254, 155, 226, 206,
        ];

        assert(hash.len() == 64_usize, 'wrong output length');

        assert_eq!(span, expected.span())
    }

    #[test]
    fn test_blake2b_8bytes_32() {
        let input = array![1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 8_u8];
        let outlen = 32_u32;
        let personalization = [
            0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ];

        let hash = blake2b_hash(input, outlen, personalization);
        let span = hash.span();

        let expected: [u8; 32] = [
            234, 45, 75, 194, 31, 83, 25, 252, 92, 151, 178, 38, 110, 80, 35, 185, 67, 150, 205, 45,
            26, 249, 1, 186, 205, 43, 229, 150, 42, 112, 180, 229,
        ];

        assert(hash.len() == 32_usize, 'wrong output length');

        assert_eq!(span, expected.span())
    }
}
