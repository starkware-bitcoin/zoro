//! Zcash block header and block data helpers.
//!
//! The data is expected to be prepared in advance and passed as program arguments. We only keep the
//! fields that cannot be derived from the execution context (e.g. previous block hash belongs to
//! the chain state, while the merkle root can be recomputed from the transaction list).

use consensus::params::{EQUIHASH_INDICES_TOTAL, EQUIHASH_SOLUTION_SIZE_BYTES};
use core::fmt::{Display, Error, Formatter};
use core::traits::DivRem;
use utils::blake2s_hasher::{Blake2sDigest, Blake2sHasher};
use utils::double_sha256::double_sha256_word_array;
use utils::hash::Digest;
use utils::word_array::{WordArray, WordArrayTrait};

/// Represents a block in the blockchain.
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct Block {
    /// Block header.
    pub header: Header,
    /// Transaction data: either merkle root or list of transactions.
    pub data: TransactionData,
}

/// Represents block contents.
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub enum TransactionData {
    /// Merkle root of all transactions in the block.
    /// This variant is used for header-only validation mode (light client).
    MerkleRoot: Digest,
}

/// Represents a block header.
/// https://zips.z.cash/protocol/protocol.pdf
///
/// NOTE that some of the fields are missing, that's intended.
/// The point of the client is to calculate next chain state from the previous
/// chain state and block data in a provable way.
/// The proof can be later used to verify that the chain state is valid.
/// In order to do the calculation we just need data about the block that is strictly necessary,
/// but not the data we can calculate like merkle root or data that we already have
/// like previous_block_hash (in the previous chain state).
#[derive(Drop, Copy, Debug, PartialEq, Serde)]
pub struct Header {
    /// The version of the block.
    pub version: u32,
    /// Hash of the Sapling (or reserved pre-Sapling) commitment tree.
    pub final_sapling_root: Digest,
    /// The timestamp of the block.
    pub time: u32,
    /// The difficulty target for mining the block.
    /// Not strictly necessary since it can be computed from target,
    /// but it is cheaper to validate than compute.
    pub bits: u32,
    /// The 256-bit nonce used by Equihash.
    pub nonce: Digest,
    /// Equihash solution indices (512 x 21-bit indices for n=200, k=9).
    pub indices: Span<u32>,
}

impl HeaderDefault of Default<Header> {
    fn default() -> Header {
        Header {
            version: 0,
            final_sapling_root: Default::default(),
            time: 0,
            bits: 0,
            nonce: Default::default(),
            indices: array![].span(),
        }
    }
}

#[generate_trait]
pub impl BlockHashImpl of BlockHash {
    /// Computes the hash of the block header given the missing fields.
    fn hash(self: @Header, prev_block_hash: Digest, merkle_root: Digest) -> Digest {
        let words = build_header_word_array(self, prev_block_hash, merkle_root);
        double_sha256_word_array(words)
    }

    /// Computes the Blake2s digest of the block header.
    fn blake2s_digest(
        self: @Header, prev_block_hash: Digest, merkle_root: Digest,
    ) -> Blake2sDigest {
        let words = build_header_word_array(self, prev_block_hash, merkle_root);
        let (full_words, last_word, last_bytes) = words.into_components();
        let mut hasher = Blake2sHasher::new();

        let mut words_span = full_words.span();
        while let Option::Some(chunk) = words_span.multi_pop_front::<16>() {
            hasher.compress_block((*chunk).unbox());
        }

        let mut block_words: Array<u32> = array![];
        for word in words_span {
            block_words.append(*word);
        }

        if last_bytes != 0 {
            block_words.append(last_word);
        }

        if block_words.len() == 16 {
            let mut span = block_words.span();
            let chunk = span.multi_pop_front::<16>().expect('Missing final Blake2s block');
            hasher.compress_block((*chunk).unbox());
            block_words = array![];
        }

        hasher.finalize(block_words.span())
    }
}


/// `Display` trait implementation for `Block`.
impl BlockDisplay of Display<Block> {
    fn fmt(self: @Block, ref f: Formatter) -> Result<(), Error> {
        let data = match *self.data {
            TransactionData::MerkleRoot(root) => format!("{}", root),
        };
        let str: ByteArray = format!(" Block {{ header: {}, data: {} }}", *self.header, @data);
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Display` trait implementation for `Header`.
impl HeaderDisplay of Display<Header> {
    fn fmt(self: @Header, ref f: Formatter) -> Result<(), Error> {
        let [n0, n1, n2, n3, n4, n5, n6, n7] = (*self.nonce.value);
        let str: ByteArray = format!(
            "Header {{ version: {}, time: {}, bits: {}, nonce: [{}, {}, {}, {}, {}, {}, {}, {}], indices_count: {}, final_sapling_root: {} }}",
            *self.version,
            *self.time,
            *self.bits,
            n0,
            n1,
            n2,
            n3,
            n4,
            n5,
            n6,
            n7,
            self.indices.len(),
            *self.final_sapling_root,
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

/// `Display` trait implementation for `TransactionData`.
impl TransactionDataDisplay of Display<TransactionData> {
    fn fmt(self: @TransactionData, ref f: Formatter) -> Result<(), Error> {
        match *self {
            TransactionData::MerkleRoot(root) => f.buffer.append(@format!("MerkleRoot: {}", root)),
        }
        Result::Ok(())
    }
}

#[cfg(test)]
mod tests {
    use consensus::params::{GENESIS_BITS, GENESIS_BLOCK_HASH, GENESIS_MERKLE_ROOT, GENESIS_TIME};
    use utils::blake2s_hasher::Blake2sDigestIntoU256;
    use utils::hash::Digest;
    use super::{BlockHash, Header};

    #[test]
    fn test_genesis_block_hash_matches_chainparams() {
        let header = genesis_header();
        let prev_block_hash: Digest = 0_u256.into();
        let merkle_root: Digest = GENESIS_MERKLE_ROOT.into();
        let block_hash_result: Digest = header.hash(prev_block_hash, merkle_root);
        assert_eq!(GENESIS_BLOCK_HASH.into(), block_hash_result);
    }

    #[test]
    fn test_merkle_root_changes_hash() {
        let header = genesis_header();
        let prev_block_hash: Digest = 0_u256.into();
        let merkle_root: Digest = (GENESIS_MERKLE_ROOT + 1_u256).into();

        let block_hash_result: Digest = header.hash(prev_block_hash, merkle_root);

        assert_ne!(GENESIS_BLOCK_HASH.into(), block_hash_result);
    }

    #[test]
    fn test_prev_block_hash_changes_hash() {
        let header = genesis_header();
        let prev_block_hash: Digest = 1_u256.into();
        let merkle_root: Digest = GENESIS_MERKLE_ROOT.into();
        let block_hash_result: Digest = header.hash(prev_block_hash, merkle_root);
        assert_ne!(GENESIS_BLOCK_HASH.into(), block_hash_result);
    }

    #[test]
    fn test_blake2s_digest_depends_on_header() {
        let header = genesis_header();
        let prev_block_hash: Digest = 0_u256.into();
        let merkle_root: Digest = GENESIS_MERKLE_ROOT.into();
        let digest: u256 = header.blake2s_digest(prev_block_hash, merkle_root).into();
        let flipped_header = Header { version: 5, ..header };
        let flipped_digest: u256 = flipped_header
            .blake2s_digest(prev_block_hash, merkle_root)
            .into();
        assert_ne!(digest, flipped_digest);
    }

    fn genesis_header() -> Header {
        Header {
            version: 4_u32,
            final_sapling_root: Default::default(),
            time: GENESIS_TIME,
            bits: GENESIS_BITS,
            nonce: GENESIS_NONCE.into(),
            indices: genesis_solution_indices(),
        }
    }

    fn genesis_solution_indices() -> Span<u32> {
        array![
            337, 162818, 173507, 416981, 704140, 1424800, 773784, 1886940, 222191, 2015828, 1282840,
            1290601, 539462, 1182227, 736622, 1337441, 277148, 1008832, 722441, 1346945, 1194059,
            1854153, 1299284, 1839899, 656953, 1041084, 1031396, 1921328, 971842, 1815071, 1475119,
            1742446, 9257, 1794290, 1054432, 1546023, 84136, 1868620, 1062243, 1938202, 85249,
            1143160, 313387, 1413719, 103735, 1562646, 106954, 1618713, 16284, 427369, 498814,
            1263477, 74332, 327699, 237311, 362681, 30424, 50585, 792437, 995410, 1270400, 1878508,
            1588465, 1730630, 14134, 788737, 659471, 1524747, 122173, 813508, 1081249, 2060599,
            436521, 690668, 1033685, 1445247, 471417, 545754, 1431894, 1831579, 33074, 296206,
            343226, 722826, 142443, 877882, 571512, 1082900, 92206, 919735, 740292, 1329214, 232809,
            1715767, 437848, 1231433, 30604, 492578, 233126, 1643945, 75651, 176748, 88888, 1494544,
            162117, 1066451, 1150176, 1726210, 178067, 710621, 730034, 2063330, 42139, 1113982,
            348587, 1038669, 560064, 1485913, 879709, 1351899, 77185, 383075, 264268, 1020228,
            495154, 1071950, 793559, 1498757, 11193, 538530, 667992, 1934214, 962917, 1303206,
            983114, 1291016, 25948, 1126615, 1060699, 1147945, 286061, 386557, 1327261, 1416367,
            314774, 1771597, 740721, 1212496, 689204, 2068098, 1163247, 1630954, 436728, 1378464,
            733865, 1657492, 694104, 1378980, 1361803, 1499665, 16812, 1014682, 169504, 909346,
            851039, 1209720, 1046870, 1650837, 56837, 551366, 1058829, 1142029, 450273, 1277795,
            998408, 1491141, 56769, 931711, 1006256, 1755871, 405133, 879223, 628240, 1650824,
            553727, 809480, 730714, 1465537, 639251, 1415565, 858416, 1636331, 49088, 1319086,
            335831, 401495, 183316, 1761890, 226658, 1302209, 80633, 973388, 414540, 661135, 394066,
            1322885, 617741, 1977246, 59949, 415624, 382583, 781493, 717743, 1273605, 1475833,
            1724619, 495551, 2067708, 1258550, 1376063, 1124573, 1675735, 1361531, 1785081, 50541,
            367520, 1866802, 2094046, 783884, 1215976, 1109309, 1805821, 303156, 686177, 495678,
            699299, 826989, 1871014, 1292938, 1952625, 116031, 2031055, 1138155, 1523627, 258893,
            786773, 1300479, 2056284, 157129, 1652570, 1022814, 1179904, 690969, 2028721, 1229696,
            2011815, 1187, 1294178, 219379, 477928, 187006, 1861355, 206323, 302103, 357455, 606037,
            828396, 1430843, 1350008, 1898405, 1951098, 2020484, 93362, 901909, 750491, 1459583,
            670909, 973184, 803404, 1195448, 361363, 657020, 761446, 899315, 412004, 940070,
            1146880, 1626363, 76123, 1929055, 383425, 1361566, 893286, 1990681, 928045, 1183492,
            119499, 1599576, 883655, 2061665, 1683689, 1932397, 1758469, 1865719, 264979, 1601028,
            508303, 705799, 511418, 1160194, 1129631, 1511284, 327198, 1991627, 1744179, 1991006,
            834154, 1808831, 1180420, 1742218, 48566, 1246678, 1991105, 2007123, 118011, 1505566,
            869572, 1326190, 396952, 1831689, 617216, 1367610, 501029, 790467, 804504, 1244706,
            228599, 1702129, 845887, 1707823, 525628, 889799, 1682146, 1901050, 683745, 1323869,
            1491295, 1566223, 860279, 1077165, 1808183, 1959079, 97443, 1470968, 124011, 888315,
            443204, 863889, 1975175, 1991432, 268155, 295365, 725212, 2080475, 606109, 1595770,
            1475642, 1993771, 220717, 1917655, 723462, 825361, 286615, 1302294, 1208763, 1225574,
            224337, 1581280, 351786, 365950, 736966, 1163628, 909041, 985934, 43851, 1775005,
            1491661, 1996770, 76886, 1644417, 578624, 1039792, 196968, 1398242, 987081, 1329731,
            872603, 1136103, 1125023, 1172987, 84787, 1068527, 1160789, 1830147, 208995, 2074879,
            982182, 1951639, 248185, 1837879, 301386, 694955, 509794, 1019585, 790957, 1373420,
            55113, 1288850, 963501, 1358464, 929255, 989789, 1413087, 1689791, 255943, 603911,
            442871, 1691521, 838911, 938951, 1348095, 1458159, 58829, 550088, 992265, 1021643,
            130896, 1652372, 355238, 2013033, 193638, 1821815, 459254, 1437744, 480683, 1681933,
            1157071, 1885041, 77296, 664291, 1578734, 2020863, 227130, 1199303, 1201190, 1827156,
            404616, 933754, 879502, 1749028, 979897, 1538093, 1245530, 1761446, 314242, 1238331,
            967129, 1523775, 618271, 1264565, 699820, 1458220, 335312, 483818, 544295, 553515,
            399587, 1783649, 1103919, 1449867, 149039, 356826, 1498391, 1961892, 669264, 956244,
            1297069, 1700830, 226053, 237259, 1286289, 1954928, 809913, 1058497, 999376, 1297186,
            152799, 1503639, 783401, 846918, 514271, 1460861, 901697, 1897221, 270966, 325298,
            580431, 1350939, 1024861, 1050386, 1263392, 1892695,
        ]
            .span()
    }

    const GENESIS_NONCE: u256 =
        0x0000000000000000000000000000000000000000000000000000000000001257_u256;
}

fn build_header_word_array(
    header: @Header, prev_block_hash: Digest, merkle_root: Digest,
) -> WordArray {
    let mut words: WordArray = Default::default();

    words.append_u32_le(*header.version);
    words.append_span(prev_block_hash.value.span());
    words.append_span(merkle_root.value.span());
    words.append_span(header.final_sapling_root.value.span());
    words.append_u32_le(*header.time);
    words.append_u32_le(*header.bits);

    words.append_span(header.nonce.value.span());

    append_compact_size(EQUIHASH_SOLUTION_SIZE_BYTES, ref words);
    append_solution_bytes(*header.indices, ref words);

    words
}

fn append_solution_bytes(mut indices: Span<u32>, ref words: WordArray) {
    // Loop thru 8 indices at a time to build 21 bytes (168 bits) chunks
    // Hardcoded shift values: 1 << n for n = 147, 126, 105, 84, 63, 42, 21, 0 (MSB-first)
    let mut start_idx: u32 = 0;
    let total_indices: u32 = EQUIHASH_INDICES_TOTAL; // Number of indices (not bytes)
    while start_idx != total_indices {
        let chunk: felt252 = (*indices.pop_front().unwrap()).into()
            * 178405961588244985132285746181186892047843328
            + (*indices.pop_front().unwrap()).into() * 85070591730234615865843651857942052864
            + (*indices.pop_front().unwrap()).into() * 40564819207303340847894502572032
            + (*indices.pop_front().unwrap()).into() * 19342813113834066795298816
            + (*indices.pop_front().unwrap()).into() * 9223372036854775808
            + (*indices.pop_front().unwrap()).into() * 4398046511104
            + (*indices.pop_front().unwrap()).into() * 2097152
            + (*indices.pop_front().unwrap()).into();
        words.append_bytes_21(chunk);
        start_idx = start_idx + 8;
    }
}

fn append_compact_size(len: usize, ref words: WordArray) {
    if len < 253 {
        words.append_u8(len.try_into().unwrap());
    } else if len < 65536 {
        words.append_u8(253);
        let (hi, lo) = DivRem::div_rem(len, 0x100);
        words.append_u8(lo.try_into().unwrap());
        words.append_u8(hi.try_into().unwrap());
    } else {
        words.append_u8(254);
        words.append_u32_le(len);
    }
}
