use consensus::types::block::Block;
use consensus::types::chain_state::ChainState;
use consensus::validation::header::validate_block_header;
use core::serde::Serde;


/// Integration testing program arguments.
#[derive(Drop)]
struct Args {
    /// Current (initial) chain state.
    chain_state: ChainState,
    /// Batch of blocks that have to be applied to the current chain state.
    blocks: Array<Block>,
    /// Expected chain state (that we want to compare the result with).
    expected_chain_state: ChainState,
}

/// Integration testing program entrypoint.
///
/// Receives arguments in a serialized format (Cairo serde).
/// Panics in case of a validation error or chain state mismatch.
/// Prints result to the stdout.
#[executable]
fn main(args: Args) {
    println!("Running integration test... ");
    let Args { mut chain_state, blocks, expected_chain_state } = args;

    for block in blocks {
        match validate_block_header(chain_state, block) {
            Result::Ok(new_chain_state) => { chain_state = new_chain_state; },
            Result::Err(err) => {
                println!("FAIL: error='{}'", err);
                panic!();
            },
        }
    }

    if chain_state != expected_chain_state {
        println!(
            "FAIL: error='expected chain state {:?}, actual {:?}'",
            expected_chain_state,
            chain_state,
        );
        panic!();
    }

    println!("OK");
}

/// Workaround for handling missing `utreexo_args` field.
/// Rough analogue of `#[serde(default)]`.
impl ArgsSerde of Serde<Args> {
    fn serialize(self: @Args, ref output: Array<felt252>) {
        panic!("not implemented");
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Args> {
        let chain_state: ChainState = Serde::deserialize(ref serialized).expect('chain_state');
        let blocks: Array<Block> = Serde::deserialize(ref serialized).expect('blocks');
        let expected_chain_state: ChainState = Serde::deserialize(ref serialized)
            .expect('expected_chain_state');

        Option::Some(Args { chain_state, blocks, expected_chain_state })
    }
}
