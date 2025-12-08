//! Work verification utilities for ensuring sufficient confirmations on top of a target block.

use num_bigint::BigUint;
use std::str::FromStr;

use crate::{proof::ChainState, verify::VerifierConfig};

/// Verify that there is enough work added on top of the target block.
pub fn verify_subchain_work(
    _block_height: u32,
    _chain_state: &ChainState,
    _config: &VerifierConfig,
) -> anyhow::Result<()> {
    // ToDo!!
    Ok(())
}

/// Compute the expected work for a single block given the target difficulty.
fn _compute_work_from_target(target: &BigUint) -> BigUint {
    // 2^256
    let max_work = BigUint::from_str(
        "115792089237316195423570985008687907853269984665640564039457584007913129639936",
    )
    .unwrap();
    max_work / (target + BigUint::from(1_u32))
}
