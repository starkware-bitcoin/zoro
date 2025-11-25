//! Merkle Mountain Range implementation.
//! Uses Blake2s for the internal tree, and can optionally produce a Blake2b digest.

use core::fmt::{Display, Error, Formatter};
use core::option::OptionTrait;
use core::traits::TryInto;
use crate::blake2b::{Blake2bDigest, blake2b_hash};
use crate::blake2s_hasher::{
    Blake2sDigest, Blake2sDigestFromU256, Blake2sDigestIntoU256, Blake2sDigestPartialEq,
    Blake2sHasher, blake2s_hash_pair,
};
use crate::numeric::u256_to_u32x8;

/// MMR accumulator state.
#[derive(Drop, Copy, PartialEq, Serde, Debug)]
pub struct MMR {
    /// Roots of the perfect binary Merkle trees.
    /// Index is the root height, None means a gap.
    pub roots: Span<Option<Blake2sDigest>>,
}

/// `Default` trait implement for `MMR`.
pub impl MMRDefault of Default<MMR> {
    fn default() -> MMR {
        MMR { roots: array![Option::<Blake2sDigest>::None].span() }
    }
}

/// `Display` trait implement for `MMR`.
impl MMRDisplay of Display<MMR> {
    fn fmt(self: @MMR, ref f: Formatter) -> Result<(), Error> {
        let str: ByteArray = format!("MMR {{ roots: {} }}", (*self.roots).len());
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Serde` implementation that deserializes an `Option<Blake2sDigest>` value from a `felt252`
/// array.
/// Every digest is encoded by two felts (high and low parts of u256).
/// If both values are zero, it is read as `None`, otherwise the digest is read as `Some(digest)`.
pub impl MaybeBlake2sDigestSerde of Serde<Option<Blake2sDigest>> {
    fn serialize(self: @Option<Blake2sDigest>, ref output: Array<felt252>) {
        assert!(false, "not implemented");
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Option<Blake2sDigest>> {
        let high: u128 = Serde::deserialize(ref serialized).expect('digest::high');
        let low: u128 = Serde::deserialize(ref serialized).expect('digest::low');
        if high == 0 && low == 0 {
            Some(None)
        } else {
            let digest = Blake2sDigestFromU256::into(u256 { high, low });
            Some(Some(digest))
        }
    }
}


#[generate_trait]
pub impl MMRImpl of MMRTrait {
    /// Construct MMR from an array of roots.
    fn new(mut roots: Array<Option<Blake2sDigest>>) -> MMR {
        // Check if terminates with `None`
        if (roots[roots.len() - 1].is_some()) {
            roots.append(None);
        }
        MMR { roots: roots.span() }
    }

    /// Adds an element to the accumulator, return the new MMR.
    fn add(self: @MMR, leaf: Blake2sDigest) -> MMR {
        let mut new_roots: Array<Option<Blake2sDigest>> = Default::default();
        let mut first_none_found: bool = false;
        let mut node = leaf;

        for root in self.roots {
            if !first_none_found {
                if let Some(root) = root {
                    node = blake2s_hash_pair(*root, node);
                    new_roots.append(None);
                } else {
                    first_none_found = true;
                    new_roots.append(Some(node));
                }
            } else {
                new_roots.append(*root);
            }
        }

        // Check if terminates with `None`
        if (new_roots[new_roots.len() - 1].is_some()) {
            new_roots.append(None);
        }

        MMR { roots: new_roots.span() }
    }

    /// Squash MMR roots into a single Blake2s digest.
    fn blake2s_digest(self: @MMR) -> Blake2sDigest {
        let mut hasher = Blake2sHasher::new();
        let mut roots = *self.roots;

        while let Some(pair) = roots.multi_pop_front::<2>() {
            let [r0, r1] = pair.unbox();
            let [a, b, c, d, e, f, g, h] = r0.map_or([0; 8], |r| r.unbox());
            let [i, j, k, l, m, n, o, p] = r1.map_or([0; 8], |r| r.unbox());
            let block = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p];
            if roots.is_empty() {
                hasher.finalize_block(block, 64);
            } else {
                hasher.compress_block(block);
            }
        }

        if !roots.is_empty() {
            // NOTE that last root is always None
            hasher.finalize_block([0; 16], 32);
        }

        hasher.digest()
    }

    /// Squash MMR roots into a 32-byte Blake2b digest.
    fn blake2b_digest(self: @MMR) -> Blake2bDigest {
        let blake2s_root = self.blake2s_digest();
        let bytes = blake2s_digest_to_le_bytes(blake2s_root);
        blake2b_hash(bytes, 32_u32, BLAKE2B_PERSONALIZATION)
    }
}

const BLAKE2B_PERSONALIZATION: [u8; 16] = [0_u8; 16];

fn blake2s_digest_to_le_bytes(digest: Blake2sDigest) -> Array<u8> {
    let value: u256 = Blake2sDigestIntoU256::into(digest);
    u256_to_le_bytes(value)
}

fn u256_to_le_bytes(value: u256) -> Array<u8> {
    let mut bytes: Array<u8> = array![];
    let mut words = u256_to_u32x8(value).span();
    let mut idx = 0_usize;
    while idx < 8_usize {
        append_u32_le_bytes(ref bytes, *words.pop_front().unwrap());
        idx += 1_usize;
    }
    bytes
}

fn append_u32_le_bytes(ref bytes: Array<u8>, value: u32) {
    let mut tmp: u64 = value.into();
    let mut i = 0;
    while i < 4_usize {
        let byte = (tmp % 256_u64).try_into().unwrap();
        bytes.append(byte);
        tmp = tmp / 256_u64;
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use core::box::BoxImpl;
    use super::*;

    #[test]
    fn test_mmr_add() {
        let mmr: MMR = Default::default();
        let leaf = Blake2sDigestFromU256::into(
            0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256,
        );

        // Add first leave to empty accumulator
        let mmr = mmr.add(leaf);

        let expected: Span<Option<Blake2sDigest>> = array![
            Some(
                Blake2sDigestFromU256::into(
                    0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256,
                ),
            ),
            None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "cannot add first leave");

        // Add second leave
        let mmr = mmr.add(leaf);

        let expected: Span<Option<Blake2sDigest>> = array![
            Option::None,
            Option::Some(
                Blake2sDigestFromU256::into(
                    0x693aa1ab81c6362fe339fc4c7f6d8ddb1e515701e58c5bb2fb54a193c8287fdc_u256,
                ),
            ),
            Option::None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "cannot add second leave");

        // Add thirdth leave
        let mmr = mmr.add(leaf);

        let expected: Span<Option<Blake2sDigest>> = array![
            Some(
                Blake2sDigestFromU256::into(
                    0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256,
                ),
            ),
            Some(
                Blake2sDigestFromU256::into(
                    0x693aa1ab81c6362fe339fc4c7f6d8ddb1e515701e58c5bb2fb54a193c8287fdc_u256,
                ),
            ),
            None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "cannot add thirdth leave");

        // Add fourth leave
        let mmr = mmr.add(leaf);

        let expected: Span<Option<Blake2sDigest>> = array![
            None, None,
            Some(
                Blake2sDigestFromU256::into(
                    0x488a5ed31744187c70a57c092e2c86742518ec5acea240726789d8b1af2b1e0d_u256,
                ),
            ),
            None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "cannot add fourth leave");

        // Add fifth leave
        let mmr = mmr.add(leaf);

        let expected: Span<Option<Blake2sDigest>> = array![
            Some(
                Blake2sDigestFromU256::into(
                    0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256,
                ),
            ),
            None,
            Some(
                Blake2sDigestFromU256::into(
                    0x488a5ed31744187c70a57c092e2c86742518ec5acea240726789d8b1af2b1e0d_u256,
                ),
            ),
            None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "cannot add fifth leave");
    }

    #[test]
    fn test_root_hash() {
        let mut mmr: Box<MMR> = BoxImpl::new(Default::default());
        let leaf: Blake2sDigest =
            0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256
            .into();
        // Add 15 blocks
        for _ in 0..15_usize {
            mmr = BoxImpl::new(mmr.add(leaf));
        }
        // Compute the root hash
        let root_hash: u256 = mmr.blake2s_digest().into();
        assert_eq!(
            root_hash, 0x19f148fb4f9b5e5bac1c12594b8e4b2d4b94d12c073b92e2b3d83349909613b6_u256,
        );
    }

    #[test]
    fn test_mmr_blake2b_digest() {
        let mut mmr: Box<MMR> = BoxImpl::new(Default::default());
        let leaf = Blake2sDigestFromU256::into(
            0xc713e33d89122b85e2f646cc518c2e6ef88b06d3b016104faa95f84f878dab66_u256,
        );
        for _ in 0..15_usize {
            mmr = BoxImpl::new(mmr.add(leaf));
        }
        let digest = mmr.blake2b_digest();
        let expected: Array<u8> = array![
            0x80_u8, 0xd0, 0xdd, 0xd9, 0x3a, 0x8c, 0xee, 0x2e, 0x6d, 0x31, 0x9c, 0x27, 0x56, 0xad,
            0xdb, 0x8c, 0x38, 0x46, 0x0d, 0xa5, 0x85, 0xbc, 0x6a, 0x39, 0xb3, 0x59, 0x8b, 0xa1,
            0x93, 0x90, 0xfa, 0x68,
        ];
        assert_eq!(digest.span(), expected.span(), "invalid Blake2b digest");
    }
}
