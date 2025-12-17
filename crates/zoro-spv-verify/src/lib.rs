//! Raito SPV verification library
//!
//! This crate provides verification routines for compressed SPV proofs, including transaction,
//! block MMR, Cairo recursive proof, and subchain work checks.
//!
//! # Full Inclusion Proof
//!
//! A full inclusion proof chains three layers of verification:
//! 1. **Chain State Proof**: Cairo STARK proof that chain state at height H is valid
//! 2. **Block Inclusion Proof**: FlyClient MMR proof that block B is in the chain  
//! 3. **Transaction Inclusion Proof**: Merkle proof that transaction T is in block B
//!
//! This allows verifying that a transaction is confirmed with N confirmations
//! without trusting any third party.

pub mod proof;
pub mod verify;
pub mod work;

pub use proof::{
    BlockInclusionProof, BootloaderOutput, ChainState, ChainStateProof, CompressedSpvProof,
    FullInclusionProof, TaskResult, TransactionInclusionProof,
};
pub use verify::{
    verify_block_inclusion, verify_chain_state, verify_full_inclusion_proof,
    verify_full_inclusion_proof_with_options, verify_proof, verify_transaction,
    VerificationResult, VerifierConfig, VerifyOptions,
};
pub use work::verify_subchain_work;
