use consensus::params::{GENESIS_BITS, GENESIS_MERKLE_ROOT, GENESIS_TIME};
use consensus::types::block::{Block, BlockHash, Header, TransactionData};
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
    /// Merkle Mountain Range of the block hashes.
    block_mmr: MMR,
    /// Proof of the previous chain state transition.
    /// If set to None, the chain state is assumed to be the genesis state.
    chain_state_proof: Option<CairoProof>,
}

#[derive(Drop, Serde)]
struct Result {
    /// Hash of the chain state after the blocks have been applied.
    chain_state_hash: u256,
    /// Hash of the roots of the Merkle Mountain Range of the block hashes.
    block_mmr_hash: u256,
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
fn main(args: Args) -> Result {
    let Args { chain_state, blocks, chain_state_proof, block_mmr } = args;

    let mut prev_result = if let Some(proof) = chain_state_proof {
        let res = get_prev_result(proof);
        // Check that the provided chain state matches the final state hash of the previous run.
        assert(
            res.chain_state_hash == chain_state.blake2s_digest().into(), 'Invalid initial state',
        );
        // Check that the provided block MMR hash matches the hash of the block MMR
        assert(res.block_mmr_hash == block_mmr.blake2s_digest().into(), 'Invalid block MMR hash');
        res
    } else {
        assert(chain_state == Default::default(), 'Invalid genesis state');
        assert(block_mmr == genesis_block_mmr(), 'Invalid genesis block MMR');
        Result {
            chain_state_hash: chain_state.blake2s_digest().into(),
            block_mmr_hash: block_mmr.blake2s_digest().into(),
            bootloader_hash: 0,
            program_hash: 0,
        }
    };

    let mut current_chain_state = chain_state;
    let mut current_block_mmr = BoxImpl::new(block_mmr);

    // Validate the blocks and update the current chain state
    for block in blocks {
        // Update the block MMR
        let prev_block_hash = current_chain_state.best_block_hash;
        let merkle_root = match block.data {
            TransactionData::MerkleRoot(root) => root,
            TransactionData::Transactions(_) => panic!("Expected Merkle root"),
        };
        current_block_mmr =
            BoxImpl::new(
                current_block_mmr.add(block.header.blake2s_digest(prev_block_hash, merkle_root)),
            );

        // Validate the block header
        match validate_block_header(current_chain_state, block) {
            Ok(new_chain_state) => { current_chain_state = new_chain_state; },
            Err(err) => panic!("FAIL: error='{}'", err),
        };
    }

    println!("OK");

    Result {
        chain_state_hash: current_chain_state.blake2s_digest().into(),
        block_mmr_hash: current_block_mmr.blake2s_digest().into(),
        bootloader_hash: prev_result.bootloader_hash,
        program_hash: prev_result.program_hash,
    }
}

/// Verify Cairo proof, extract and validate the task output.
fn get_prev_result(proof: CairoProof) -> Result {
    let VerificationOutput { program_hash, output } = get_verification_output(proof: @proof);

    // Verify the proof
    match verify_cairo(proof) {
        Ok(_) => {},
        Err(e) => panic!("Invalid proof: {:?}", e),
    }

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
        task_output_size == 8, 'Unexpected task output size',
    ); // 1 felt for program hash, 6 for output, 1 for the size

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
        block_mmr_hash: task_result.block_mmr_hash,
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
        solution: genesis_solution_words(),
    };
    let merkle_root = GENESIS_MERKLE_ROOT.into();
    let prev_block_hash = 0_u256.into();
    let root = genesis_block_header.blake2s_digest(prev_block_hash, merkle_root);
    MMRTrait::new(array![Some(root)])
}

fn genesis_solution_words() -> Span<u32> {
    array![
        0x9f880a00, 0x864b8500, 0x5f55cd65, 0x81f65646, 0xca1cd379, 0x7f1f1bdc, 0x262795b0,
        0x94163b31, 0x2848a31d, 0xd4ad674d, 0xd4216168, 0x1630d9e3, 0xd848130c, 0xf1251c19,
        0x6a7a262b, 0x501b139c, 0xaff8cb31, 0xd5c9791f, 0x216a0713, 0xd07ec86e, 0x6e96fa45,
        0xd84e2101, 0xc12da03c, 0xa4707279, 0x320d7254, 0x937dac06, 0x0c680a1a, 0x90095e5c,
        0x70255957, 0x60df9bca, 0x58393458, 0xfc0119b3, 0x4f5aa1e1, 0x7734fd38, 0x142e9150,
        0xdf734c00, 0x03b988e5, 0x6631c0b6, 0xf3ea2e58, 0x40b12905, 0x07b3a772, 0x46683a9e,
        0x02b3b901, 0x1f205440, 0xeeb04074, 0x12a7b19e, 0x713ff40f, 0x4a493537, 0x8b1f7ba2,
        0xf3d760ab, 0x4fa1bc98, 0xdb2abb6a, 0x09049bf2, 0x8a432191, 0x78b07479, 0xb53516a1,
        0x0f17e994, 0x0b148610, 0x2d827341, 0x448997d6, 0xb4c6e183, 0xd5dcb8e8, 0x49ca12cb,
        0xe161bc03, 0x4d1d8708, 0x93905a91, 0xb0c98ac1, 0xce16672b, 0x2cca1310, 0x19e37411,
        0x2170a5c1, 0x5fabc95b, 0x5f766475, 0x2405e27b, 0x8adf3fdc, 0x94fd56a3, 0x5ae045d4,
        0x8bad65b1, 0x09dba0b4, 0x1876096c, 0xf99810c8, 0x19c74314, 0x83396d41, 0x85def67a,
        0x0dca5d01, 0xb16294e8, 0x586738d8, 0x998acfb2, 0xb35309e0, 0xe42a0308, 0x5ee0354c,
        0x924218b7, 0x9797b62e, 0xb51388f6, 0x6c26af9c, 0x5613c2b6, 0x0528e39a, 0x7e1a4205,
        0xfd370a3a, 0x35eae2f8, 0x2842c54f, 0x94536516, 0xac4b45a9, 0x98922a54, 0x11e276f1,
        0xde630d02, 0x402c85e6, 0x7e2602de, 0xe1d5c92f, 0x30d92aff, 0x2af00695, 0x50a0711a,
        0xd3d0161b, 0xfdcd706f, 0x1681e78d, 0xee06c5c0, 0xdedf8d0b, 0xadac61b5, 0xb54617f3,
        0xc232dda9, 0x43883019, 0x8216fb97, 0x65b54c16, 0x89e014cc, 0xa33566d6, 0xebf71826,
        0x0805fe05, 0xae3f8a2b, 0x66710562, 0x88896b0a, 0xde53ac6e, 0xcbd709c1, 0xa60c93b6,
        0xf368a198, 0xbe50a901, 0xbea12d15, 0x51079e2b, 0x0be29569, 0xcbbeeeac, 0xcdd77955,
        0x9fd016bc, 0x3ccb503a, 0x3fe3ff7d, 0x4f6d6826, 0x6e94f8f3, 0x985e47e6, 0xf93c7bcf,
        0x66692b06, 0x65f838e8, 0xfbe53dff, 0xa2374a06, 0x8dbba71d, 0xa20125fd, 0x204f189e,
        0x36baaa7c, 0x32f2364f, 0x5d51779a, 0x290e71cb, 0xe273bfff, 0xfa73d7bb, 0xb0a6f9b1,
        0xff7a5605, 0x135c60ff, 0xd64d4e2e, 0x20bd369f, 0x8c450510, 0x58c6d2fb, 0xa7b21e70,
        0xef1c2500, 0xe6b186d8, 0x6d81ae74, 0xac9b713f, 0x9c64be64, 0x7aa22b17, 0x4759d54f,
        0xba535dd9, 0xde73bc4c, 0x5eafb897, 0x650b84d4, 0x56c57093, 0x576437e7, 0xbb5e1ef5,
        0x49880166, 0x2cb83d92, 0x9f819a1c, 0xdbcc3c17, 0xb224338f, 0x309a6039, 0xfbd01800,
        0x5bdf4a09, 0x83b3cbd7, 0xd0e6694c, 0x658079b3, 0x0fb225c5, 0x5e960e04, 0xf71a161a,
        0x1c56f78f, 0xf1f574d8, 0xbca05ab7, 0x5820f777, 0x0f811b9e, 0x50ac1e83, 0x46dde673,
        0x93270ad0, 0x27740ff7, 0xf298f7f0, 0xe6673af5, 0x355de615, 0x40fe666e, 0x8a959a60,
        0xc1b4ed05, 0x83c3bc75, 0xe63005ea, 0x79e4db7d, 0x3c9498a8, 0xc674306e, 0xd652c2fc,
        0xa3e34d01, 0x3fb092d2, 0x12d3880d, 0xe71b22fe, 0x593c7ebe, 0xf2a07fd0, 0x369e02f4,
        0x5c351f4f, 0x53fa015d, 0xd70c0d77, 0x7ebf826d, 0x3b90f660, 0x72b7bec1, 0xa7e4fde6,
        0x9c1de50b, 0xd6c8037e, 0x61b3dfd8, 0x47ba34a2, 0x63fe70c4, 0xd9bb2008, 0x21567120,
        0xb4edfbb9, 0x65e1ce9f, 0x5e87d0ea, 0xf11a2b6c, 0xd6b5506f, 0x81c90c14, 0xcfcb2f12,
        0x374e5a7c, 0x1b66b372, 0x38088e62, 0x5954bc0a, 0x639fe557, 0xbbb10547, 0x4e0b2fde,
        0xc55e5a05, 0x9b856d67, 0x96207ee7, 0x055e642b, 0xdd0f881a, 0x450b18b0, 0x1f9e7855,
        0x36a44493, 0x57c54da8, 0xf153259e, 0x590afbe5, 0xe37b139c, 0xd0beab6c, 0xfe319831,
        0x94dffda3, 0x1e97c7dd, 0xcd02cf4b, 0xa99432c9, 0xb1e3b3aa, 0x82053b3e, 0xecf4b435,
        0xea4cba06, 0x5b679da4, 0x1607a84b, 0x7669bcf3, 0xc8f9fbb1, 0x3a3e1fbf, 0x83cdc14d,
        0x16f89cef, 0x4fb97f66, 0xf63f921e, 0x2e07ef3f, 0x1e32196a, 0x6cf91248, 0x64a8ffb0,
        0x74ad50da, 0x1769b7de, 0x1df336a3, 0x5fed03ce, 0xd5aa0303, 0x3436a8e6, 0x71c3fcf9,
        0x88826f09, 0xdd2df0b8, 0xbbf15fed, 0x1e33499d, 0xe1db844a, 0x43643154, 0xd79ade8f,
        0x4702ab1d, 0xe0dddc79, 0x5a2b60b6, 0x5c26a6e0, 0xdd4eb914, 0x0374b383, 0xcd8fb7f4,
        0xb555d52e, 0x282c4096, 0x7ad881ee, 0x874e9c90, 0x710cb322, 0x1b86ddec, 0x8b1ff605,
        0x5c793112, 0x2fbaad76, 0x1b45fade, 0x525d3a28, 0xf3b95579, 0x28981bde, 0x41e7b2e7,
        0x0647dd23, 0x9bc0dc2d, 0x13fae705, 0xa61222cb, 0xd765bcfd, 0xc4ce52e8, 0xd96fec63,
        0x48b8f529, 0x2105f33c, 0xac3db113, 0x499fb691, 0xaed1b7d1, 0x684a1cc0, 0x57e11ce4,
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
