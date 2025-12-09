use consensus::params::{GENESIS_BITS, GENESIS_MERKLE_ROOT, GENESIS_TIME};
use consensus::types::block::{Block, BlockHash, Header};
use consensus::types::chain_state::{ChainState, ChainStateHashTrait};
use consensus::validation::header::validate_block_header;
use core::box::BoxImpl;
use stwo_cairo_air::{CairoProof, VerificationOutput, get_verification_output, verify_cairo};
use utils::blake2s_hasher::{Blake2sDigestFromU256, Blake2sDigestIntoU256};
use utils::mmr::{MMR, MMRTrait};


#[derive(Drop, Serde)]
struct Args {
    /// Current (initial) chain state.
    chain_state: ChainState,
    /// Batch of blocks that have to be applied to the current chain state.
    blocks: Array<Block>,
    /// Proof of the previous chain state transition.
    /// If set to None, the chain state is assumed to be the genesis state.
    chain_state_proof: Option<CairoProof>,
}

#[derive(Drop, Serde)]
struct Result {
    /// Hash of the chain state after the blocks have been applied.
    chain_state_hash: u256,
    /// Hash of the bootloader program that was recursively verified.
    bootloader_hash: felt252,
    /// Hash of the program that was recursively verified.
    /// We cannot know the hash of the program from within the program, so we have to carry it over.
    /// This also allows composing multiple programs (e.g. if we'd need to upgrade at a certain
    /// block height).
    program_hash: felt252,
}

#[derive(Drop, Serde)]
struct BootloaderOutput {
    /// Number of tasks (must be always 1)
    n_tasks: usize,
    /// Size of the task output in felts (including the size field)
    task_output_size: usize,
    /// Hash of the payload program.
    task_program_hash: felt252,
    /// Output of the payload program.
    task_result: Result,
}

#[executable]
fn main(
    chain_state: ChainState, blocks: Array<Block>, chain_state_proof: Option<CairoProof>,
) -> Result {
    // let Args { chain_state, blocks, chain_state_proof } = args;

    let mut prev_result = if let Some(proof) = chain_state_proof {
        let res = get_prev_result(proof);
        // Check that the provided chain state matches the final state hash of the previous run.
        assert(
            res.chain_state_hash == chain_state.blake2s_digest().into(), 'Invalid initial state',
        );

        res
    } else {
        assert(chain_state == Default::default(), 'Invalid genesis state');
        Result {
            chain_state_hash: chain_state.blake2s_digest().into(),
            bootloader_hash: 0,
            program_hash: 0,
        }
    };

    let mut current_chain_state = chain_state;

    // Validate the blocks and update the current chain state
    for block in blocks {
        // Validate the block header
        match validate_block_header(current_chain_state, block) {
            Ok(new_chain_state) => { current_chain_state = new_chain_state; },
            Err(err) => panic!("FAIL: error='{}'", err),
        };
    }

    println!("OK");

    Result {
        chain_state_hash: current_chain_state.blake2s_digest().into(),
        bootloader_hash: prev_result.bootloader_hash,
        program_hash: prev_result.program_hash,
    }
}

/// Verify Cairo proof, extract and validate the task output.
fn get_prev_result(proof: CairoProof) -> Result {
    let VerificationOutput { program_hash, output } = get_verification_output(proof: @proof);

    // Verify the proof
    verify_cairo(proof);

    // Deserialize the bootloader output
    let mut serialized_bootloader_output = output.span();
    let BootloaderOutput {
        n_tasks, task_output_size, task_program_hash, task_result,
    }: BootloaderOutput =
        Serde::deserialize(ref serialized_bootloader_output).expect('Invalid bootloader output');

    // Check that the bootloader output contains exactly one task
    assert(serialized_bootloader_output.is_empty(), 'Output too long');
    assert(n_tasks == 1, 'Unexpected number of tasks');
    assert(
        task_output_size == 6, 'Unexpected task output size',
    ); // 1 felt for program hash, 4 for output, 1 for the size

    // Check that the task bootloader hash and program hash is the same as
    // the previous bootloader hash and program hash. In case of the genesis state,
    // the previous hash is 0

    if task_result.bootloader_hash != 0 {
        assert(task_result.bootloader_hash == program_hash, 'Bootloader hash mismatch')
    }
    if task_result.program_hash != 0 {
        assert(task_result.program_hash == task_program_hash, 'Program hash mismatch');
    }

    Result {
        chain_state_hash: task_result.chain_state_hash,
        bootloader_hash: program_hash,
        program_hash: task_program_hash,
    }
}

/// Create MMR at height 0 (after adding genesis block to the accumulator).
fn genesis_block_mmr() -> MMR {
    let genesis_block_header = Header {
        version: 4,
        final_sapling_root: Default::default(),
        time: GENESIS_TIME,
        bits: GENESIS_BITS,
        nonce: GENESIS_NONCE.into(),
        indices: genesis_solution_indices(),
    };
    let merkle_root = GENESIS_MERKLE_ROOT.into();
    let prev_block_hash = 0_u256.into();
    let root = genesis_block_header.blake2s_digest(prev_block_hash, merkle_root);
    MMRTrait::new(array![Some(root)])
}

/// Genesis solution indices (512 x 21-bit indices for n=200, k=9).
/// Precalculated from the genesis block solution.
fn genesis_solution_indices() -> Span<u32> {
    array![
        337, 162818, 173507, 416981, 704140, 1424800, 773784, 1886940,
        222191, 2015828, 1282840, 1290601, 539462, 1182227, 736622, 1337441,
        277148, 1008832, 722441, 1346945, 1194059, 1854153, 1299284, 1839899,
        656953, 1041084, 1031396, 1921328, 971842, 1815071, 1475119, 1742446,
        9257, 1794290, 1054432, 1546023, 84136, 1868620, 1062243, 1938202,
        85249, 1143160, 313387, 1413719, 103735, 1562646, 106954, 1618713,
        16284, 427369, 498814, 1263477, 74332, 327699, 237311, 362681,
        30424, 50585, 792437, 995410, 1270400, 1878508, 1588465, 1730630,
        14134, 788737, 659471, 1524747, 122173, 813508, 1081249, 2060599,
        436521, 690668, 1033685, 1445247, 471417, 545754, 1431894, 1831579,
        33074, 296206, 343226, 722826, 142443, 877882, 571512, 1082900,
        92206, 919735, 740292, 1329214, 232809, 1715767, 437848, 1231433,
        30604, 492578, 233126, 1643945, 75651, 176748, 88888, 1494544,
        162117, 1066451, 1150176, 1726210, 178067, 710621, 730034, 2063330,
        42139, 1113982, 348587, 1038669, 560064, 1485913, 879709, 1351899,
        77185, 383075, 264268, 1020228, 495154, 1071950, 793559, 1498757,
        11193, 538530, 667992, 1934214, 962917, 1303206, 983114, 1291016,
        25948, 1126615, 1060699, 1147945, 286061, 386557, 1327261, 1416367,
        314774, 1771597, 740721, 1212496, 689204, 2068098, 1163247, 1630954,
        436728, 1378464, 733865, 1657492, 694104, 1378980, 1361803, 1499665,
        16812, 1014682, 169504, 909346, 851039, 1209720, 1046870, 1650837,
        56837, 551366, 1058829, 1142029, 450273, 1277795, 998408, 1491141,
        56769, 931711, 1006256, 1755871, 405133, 879223, 628240, 1650824,
        553727, 809480, 730714, 1465537, 639251, 1415565, 858416, 1636331,
        49088, 1319086, 335831, 401495, 183316, 1761890, 226658, 1302209,
        80633, 973388, 414540, 661135, 394066, 1322885, 617741, 1977246,
        59949, 415624, 382583, 781493, 717743, 1273605, 1475833, 1724619,
        495551, 2067708, 1258550, 1376063, 1124573, 1675735, 1361531, 1785081,
        50541, 367520, 1866802, 2094046, 783884, 1215976, 1109309, 1805821,
        303156, 686177, 495678, 699299, 826989, 1871014, 1292938, 1952625,
        116031, 2031055, 1138155, 1523627, 258893, 786773, 1300479, 2056284,
        157129, 1652570, 1022814, 1179904, 690969, 2028721, 1229696, 2011815,
        1187, 1294178, 219379, 477928, 187006, 1861355, 206323, 302103,
        357455, 606037, 828396, 1430843, 1350008, 1898405, 1951098, 2020484,
        93362, 901909, 750491, 1459583, 670909, 973184, 803404, 1195448,
        361363, 657020, 761446, 899315, 412004, 940070, 1146880, 1626363,
        76123, 1929055, 383425, 1361566, 893286, 1990681, 928045, 1183492,
        119499, 1599576, 883655, 2061665, 1683689, 1932397, 1758469, 1865719,
        264979, 1601028, 508303, 705799, 511418, 1160194, 1129631, 1511284,
        327198, 1991627, 1744179, 1991006, 834154, 1808831, 1180420, 1742218,
        48566, 1246678, 1991105, 2007123, 118011, 1505566, 869572, 1326190,
        396952, 1831689, 617216, 1367610, 501029, 790467, 804504, 1244706,
        228599, 1702129, 845887, 1707823, 525628, 889799, 1682146, 1901050,
        683745, 1323869, 1491295, 1566223, 860279, 1077165, 1808183, 1959079,
        97443, 1470968, 124011, 888315, 443204, 863889, 1975175, 1991432,
        268155, 295365, 725212, 2080475, 606109, 1595770, 1475642, 1993771,
        220717, 1917655, 723462, 825361, 286615, 1302294, 1208763, 1225574,
        224337, 1581280, 351786, 365950, 736966, 1163628, 909041, 985934,
        43851, 1775005, 1491661, 1996770, 76886, 1644417, 578624, 1039792,
        196968, 1398242, 987081, 1329731, 872603, 1136103, 1125023, 1172987,
        84787, 1068527, 1160789, 1830147, 208995, 2074879, 982182, 1951639,
        248185, 1837879, 301386, 694955, 509794, 1019585, 790957, 1373420,
        55113, 1288850, 963501, 1358464, 929255, 989789, 1413087, 1689791,
        255943, 603911, 442871, 1691521, 838911, 938951, 1348095, 1458159,
        58829, 550088, 992265, 1021643, 130896, 1652372, 355238, 2013033,
        193638, 1821815, 459254, 1437744, 480683, 1681933, 1157071, 1885041,
        77296, 664291, 1578734, 2020863, 227130, 1199303, 1201190, 1827156,
        404616, 933754, 879502, 1749028, 979897, 1538093, 1245530, 1761446,
        314242, 1238331, 967129, 1523775, 618271, 1264565, 699820, 1458220,
        335312, 483818, 544295, 553515, 399587, 1783649, 1103919, 1449867,
        149039, 356826, 1498391, 1961892, 669264, 956244, 1297069, 1700830,
        226053, 237259, 1286289, 1954928, 809913, 1058497, 999376, 1297186,
        152799, 1503639, 783401, 846918, 514271, 1460861, 901697, 1897221,
        270966, 325298, 580431, 1350939, 1024861, 1050386, 1263392, 1892695,
    ]
        .span()
}

const GENESIS_NONCE: u256 = 0x0000000000000000000000000000000000000000000000000000000000001257_u256;

#[cfg(test)]
mod tests {
    use utils::blake2s_hasher::{Blake2sDigest, Blake2sDigestIntoU256, Blake2sDigestPartialEq};
    use super::*;

    #[test]
    fn test_genesis_block_mmr() {
        let mmr = genesis_block_mmr();
        let expected: Span<Option<Blake2sDigest>> = array![
            Some(0x0d6195eb80a1a9dcdf5fb7aaf820639b76b96fe9448b2fce9e117b6385c69c37_u256.into()),
            None,
        ]
            .span();
        assert_eq!(mmr.roots, expected, "genesis block MMR is not correct");
    }
}
