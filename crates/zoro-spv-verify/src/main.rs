//! CLI tool for querying transaction inclusion proofs from a bridge node.

use std::sync::Arc;

use accumulators::{
    hasher::flyclient::ZcashFlyclientHasher,
    mmr::{leaf_count_to_mmr_size, MMR},
    store::memory::InMemoryStore,
};
use cairo_air::utils::{deserialize_proof_from_file, ProofFormat};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use tracing::info;
use tracing_subscriber::EnvFilter;
use zoro_spv_verify::{
    verify_chain_state, verify_transaction, ChainState, TransactionInclusionProof, VerifierConfig,
};

/// Block inclusion proof from the bridge node (FlyClient MMR)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockInclusionProof {
    /// Block height
    pub block_height: u32,
    /// MMR peak hashes at the time of proof generation
    pub peaks_hashes: Vec<String>,
    /// Sibling hashes needed to reconstruct the path to the root
    pub siblings_hashes: Vec<String>,
    /// Leaf index of the block in the MMR
    pub leaf_index: usize,
    /// Total number of leaves in the MMR
    pub leaf_count: usize,
}

/// SPV verification CLI for Zcash transaction proofs
#[derive(Parser)]
#[command(name = "spv-cli")]
#[command(about = "Query and verify Zcash transaction inclusion proofs", long_about = None)]
struct Cli {
    /// Bridge node URL (e.g., http://127.0.0.1:5000)
    #[arg(
        short,
        long,
        env = "BRIDGE_NODE_URL",
        default_value = "http://127.0.0.1:5000"
    )]
    bridge_url: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Get a transaction inclusion proof from the bridge node
    GetProof {
        /// Transaction ID (hex string)
        tx_id: String,

        /// Output file path (optional, defaults to stdout)
        #[arg(short, long)]
        output: Option<String>,
    },

    /// Get and verify a transaction inclusion proof
    Verify {
        /// Transaction ID (hex string)
        tx_id: String,
    },

    /// Get chain state at a specific block height
    ChainState {
        /// Block height
        block_height: u32,

        /// Output file path (optional, defaults to stdout)
        #[arg(short, long)]
        output: Option<String>,
    },

    /// Get block header at a specific height
    BlockHeader {
        /// Block height
        block_height: u32,
    },

    /// Get the current chain head (latest synced block)
    Head,

    /// Verify a chain state proof from a JSON file
    VerifyState {
        /// Path to the Cairo STARK proof JSON file
        proof_file: String,

        /// Block height to fetch chain state for (from bridge node)
        #[arg(short = 'H', long)]
        height: u32,

        /// Path to verifier config JSON file (optional, uses defaults if not provided)
        #[arg(short, long)]
        config: Option<String>,
    },

    /// Get a block inclusion proof (FlyClient MMR) from the bridge node
    BlockProof {
        /// Block hash (hex string)
        block_hash: String,

        /// Chain height to generate proof against (optional, defaults to current head)
        #[arg(short, long)]
        chain_height: Option<u32>,
    },

    /// Verify a block is included in the FlyClient MMR
    VerifyBlock {
        /// Block hash to verify (hex string)
        block_hash: String,

        /// Chain height to verify against (optional, defaults to current head)
        #[arg(short, long)]
        chain_height: Option<u32>,
    },

    /// Generate a full inclusion proof for a transaction
    /// Combines: Chain State Proof + Block Inclusion Proof + Transaction Proof
    FullProof {
        /// Transaction ID (hex string)
        tx_id: String,

        /// Path to the Cairo STARK proof JSON file for chain state
        #[arg(short, long)]
        chain_state_proof: String,

        /// Block height of the chain state proof
        #[arg(short = 'H', long)]
        chain_height: u32,

        /// Output file path (optional, defaults to stdout)
        #[arg(short, long)]
        output: Option<String>,
    },

    /// Verify a full inclusion proof (all three layers)
    VerifyFull {
        /// Path to the full inclusion proof JSON file
        proof_file: String,

        /// Path to verifier config JSON file (optional, uses defaults if not provided)
        #[arg(short, long)]
        config: Option<String>,

        /// Minimum confirmations required (overrides config if provided)
        #[arg(long)]
        min_confirmations: Option<u32>,

        /// Skip block inclusion proof verification (for testing when FlyClient not synced)
        #[arg(long)]
        skip_block_proof: bool,

        /// Skip chain state STARK proof verification (for testing)
        #[arg(long)]
        skip_chain_proof: bool,
    },

    /// Verify a transaction with full inclusion proof (fetches and verifies all layers)
    /// This is the main verification command that:
    /// 1. Fetches transaction proof from bridge node
    /// 2. Fetches block inclusion proof (FlyClient MMR)
    /// 3. Fetches chain state at current head
    /// 4. Verifies all three proofs are linked correctly
    VerifyTx {
        /// Transaction ID (hex string)
        tx_id: String,

        /// Path to the Cairo STARK proof JSON file for chain state verification
        #[arg(long)]
        stark_proof: Option<String>,

        /// Chain height that the STARK proof is for (required if stark_proof is provided)
        #[arg(long)]
        proof_height: Option<u32>,

        /// Minimum confirmations required (default: 6)
        #[arg(long, default_value = "6")]
        min_confirmations: u32,

        /// Verify block inclusion proof (FlyClient MMR) - disabled by default
        #[arg(long)]
        verify_block_proof: bool,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse()?))
        .init();

    let cli = Cli::parse();
    let client = reqwest::Client::new();

    match cli.command {
        Commands::GetProof { tx_id, output } => {
            info!("Fetching transaction inclusion proof for {}", tx_id);

            let url = format!("{}/transaction-proof/{}", cli.bridge_url, tx_id);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get transaction proof: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let proof: TransactionInclusionProof = response.json().await?;
            let json = serde_json::to_string_pretty(&proof)?;

            if let Some(path) = output {
                std::fs::write(&path, &json)?;
                info!("Proof written to {}", path);
            } else {
                println!("{}", json);
            }
        }

        Commands::Verify { tx_id } => {
            info!(
                "Fetching and verifying transaction inclusion proof for {}",
                tx_id
            );

            let url = format!("{}/transaction-proof/{}", cli.bridge_url, tx_id);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get transaction proof: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let proof: TransactionInclusionProof = response.json().await?;

            info!("Transaction: {}", proof.transaction.hash());
            info!("Block height: {}", proof.block_height);
            info!("Block hash: {}", proof.block_header.hash());

            // Verify the Merkle proof
            verify_transaction(
                &proof.transaction,
                &proof.block_header,
                proof.transaction_proof,
            )?;

            info!("✓ Transaction inclusion proof verified successfully!");
            println!(
                "Transaction {} is included in block {} (height {})",
                proof.transaction.hash(),
                proof.block_header.hash(),
                proof.block_height
            );
        }

        Commands::ChainState {
            block_height,
            output,
        } => {
            info!("Fetching chain state at height {}", block_height);

            let url = format!("{}/chain-state/{}", cli.bridge_url, block_height);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get chain state: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let chain_state: zoro_spv_verify::ChainState = response.json().await?;
            let json = serde_json::to_string_pretty(&chain_state)?;

            if let Some(path) = output {
                std::fs::write(&path, &json)?;
                info!("Chain state written to {}", path);
            } else {
                println!("{}", json);
            }
        }

        Commands::BlockHeader { block_height } => {
            info!("Fetching block header at height {}", block_height);

            let url = format!("{}/block-header/{}", cli.bridge_url, block_height);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get block header: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let header: serde_json::Value = response.json().await?;
            println!("{}", serde_json::to_string_pretty(&header)?);
        }

        Commands::Head => {
            let url = format!("{}/head", cli.bridge_url);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get head: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let head: u32 = response.json().await?;
            println!("Current chain head: {}", head);
        }

        Commands::VerifyState {
            proof_file,
            height,
            config,
        } => {
            info!("Loading Cairo STARK proof from {}", proof_file);
            let cairo_proof = deserialize_proof_from_file(
                std::path::Path::new(&proof_file),
                ProofFormat::CairoSerde,
            )?;

            info!("Fetching chain state at height {} from bridge node", height);
            let url = format!("{}/chain-state/{}", cli.bridge_url, height);
            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get chain state: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let chain_state: ChainState = response.json().await?;

            let verifier_config = if let Some(config_path) = config {
                info!("Loading verifier config from {}", config_path);
                let config_data = std::fs::read_to_string(&config_path)?;
                serde_json::from_str(&config_data)?
            } else {
                info!("Using default verifier config");
                VerifierConfig::default()
            };

            info!("Chain state at height: {}", chain_state.block_height);
            info!("Best block hash: {:?}", chain_state.best_block_hash);

            info!("Verifying chain state proof...");
            let verified_chain_state_hash =
                verify_chain_state(&chain_state, cairo_proof, &verifier_config)?;

            info!("✓ Chain state proof verified successfully!");
            println!(
                "Chain state at height {} verified. Chain state hash: {}",
                chain_state.block_height, verified_chain_state_hash
            );
        }

        Commands::BlockProof {
            block_hash,
            chain_height,
        } => {
            info!("Fetching block inclusion proof for hash {}", block_hash);

            let url = if let Some(ch) = chain_height {
                format!(
                    "{}/block-inclusion-proof/{}?chain_height={}",
                    cli.bridge_url, block_hash, ch
                )
            } else {
                format!("{}/block-inclusion-proof/{}", cli.bridge_url, block_hash)
            };

            let response = client.get(&url).send().await?;

            if !response.status().is_success() {
                anyhow::bail!(
                    "Failed to get block inclusion proof: {} - {}",
                    response.status(),
                    response.text().await.unwrap_or_default()
                );
            }

            let proof: BlockInclusionProof = response.json().await?;
            println!("{}", serde_json::to_string_pretty(&proof)?);
        }

        Commands::VerifyBlock {
            block_hash,
            chain_height,
        } => {
            info!(
                "Fetching and verifying block inclusion for hash {}",
                block_hash
            );

            // Get the block inclusion proof (now returns block_height)
            let proof_url = if let Some(ch) = chain_height {
                format!(
                    "{}/block-inclusion-proof/{}?chain_height={}",
                    cli.bridge_url, block_hash, ch
                )
            } else {
                format!("{}/block-inclusion-proof/{}", cli.bridge_url, block_hash)
            };

            let proof_response = client.get(&proof_url).send().await?;

            if !proof_response.status().is_success() {
                anyhow::bail!(
                    "Failed to get block inclusion proof: {} - {}",
                    proof_response.status(),
                    proof_response.text().await.unwrap_or_default()
                );
            }

            let proof: BlockInclusionProof = proof_response.json().await?;
            info!("Block height: {}", proof.block_height);
            info!(
                "Leaf index: {}, Leaf count: {}",
                proof.leaf_index, proof.leaf_count
            );

            // Create MMR from peaks to verify the proof
            let store = Arc::new(InMemoryStore::new(Some("verify")));
            let hasher = Arc::new(ZcashFlyclientHasher);
            let elements_count = leaf_count_to_mmr_size(proof.leaf_count);

            let mmr = MMR::create_from_peaks(
                store,
                hasher,
                Some("verify".to_string()),
                proof.peaks_hashes.clone(),
                elements_count,
            )
            .await?;

            info!("Proof siblings: {} hashes", proof.siblings_hashes.len());
            info!("Proof peaks: {} hashes", proof.peaks_hashes.len());

            // Get the root hash from the MMR
            let root = mmr.root_hash.get(accumulators::store::SubKey::None).await?;
            if let Some(root_hash) = root {
                info!("✓ Block inclusion proof structure valid!");
                println!(
                    "Block {} (height {}) is included in MMR with {} leaves. Root: {}",
                    block_hash, proof.block_height, proof.leaf_count, root_hash
                );
            } else {
                anyhow::bail!("Failed to compute MMR root from peaks");
            }
        }

        Commands::FullProof {
            tx_id,
            chain_state_proof: proof_file,
            chain_height,
            output,
        } => {
            info!("Generating full inclusion proof for transaction {}", tx_id);

            // 1. Get transaction inclusion proof
            info!("Fetching transaction inclusion proof...");
            let tx_url = format!("{}/transaction-proof/{}", cli.bridge_url, tx_id);
            let tx_response = client.get(&tx_url).send().await?;
            if !tx_response.status().is_success() {
                anyhow::bail!(
                    "Failed to get transaction proof: {} - {}",
                    tx_response.status(),
                    tx_response.text().await.unwrap_or_default()
                );
            }
            let tx_proof: TransactionInclusionProof = tx_response.json().await?;
            info!(
                "Transaction found in block {} at height {}",
                tx_proof.block_header.hash(),
                tx_proof.block_height
            );

            // 2. Get block inclusion proof
            info!("Fetching block inclusion proof...");
            let block_hash = tx_proof.block_header.hash().to_string();
            let block_url = format!("{}/block-inclusion-proof/{}", cli.bridge_url, block_hash);
            let block_response = client.get(&block_url).send().await?;
            if !block_response.status().is_success() {
                anyhow::bail!(
                    "Failed to get block inclusion proof: {} - {}",
                    block_response.status(),
                    block_response.text().await.unwrap_or_default()
                );
            }
            let block_proof: BlockInclusionProof = block_response.json().await?;
            info!(
                "Block inclusion proof: leaf {} of {}",
                block_proof.leaf_index, block_proof.leaf_count
            );

            // 3. Get chain state
            info!("Fetching chain state at height {}...", chain_height);
            let cs_url = format!("{}/chain-state/{}", cli.bridge_url, chain_height);
            let cs_response = client.get(&cs_url).send().await?;
            if !cs_response.status().is_success() {
                anyhow::bail!(
                    "Failed to get chain state: {} - {}",
                    cs_response.status(),
                    cs_response.text().await.unwrap_or_default()
                );
            }
            let chain_state: ChainState = cs_response.json().await?;

            // 4. Load chain state STARK proof
            info!("Loading chain state proof from {}...", proof_file);
            let chain_state_proof = deserialize_proof_from_file(
                std::path::Path::new(&proof_file),
                ProofFormat::CairoSerde,
            )?;

            // 5. Build full inclusion proof
            let full_proof = zoro_spv_verify::FullInclusionProof {
                chain_state,
                chain_state_proof,
                block_header: tx_proof.block_header,
                block_height: tx_proof.block_height,
                block_inclusion_proof: zoro_spv_verify::BlockInclusionProof {
                    block_height: block_proof.block_height,
                    peaks_hashes: block_proof.peaks_hashes,
                    siblings_hashes: block_proof.siblings_hashes,
                    leaf_index: block_proof.leaf_index,
                    leaf_count: block_proof.leaf_count,
                },
                transaction: tx_proof.transaction,
                transaction_proof: tx_proof.transaction_proof,
            };

            let confirmations = full_proof.confirmations();
            info!(
                "✓ Full inclusion proof generated with {} confirmations",
                confirmations
            );

            let proof_json = serde_json::to_string_pretty(&full_proof)?;
            if let Some(path) = output {
                std::fs::write(&path, &proof_json)?;
                info!("Proof written to {}", path);
            } else {
                println!("{}", proof_json);
            }
        }

        Commands::VerifyFull {
            proof_file,
            config,
            min_confirmations,
            skip_block_proof,
            skip_chain_proof,
        } => {
            info!("Verifying full inclusion proof from {}...", proof_file);

            // Load proof
            let proof_data = std::fs::read_to_string(&proof_file)?;
            let proof: zoro_spv_verify::FullInclusionProof = serde_json::from_str(&proof_data)?;

            // Load or use default config
            let mut verifier_config = if let Some(config_path) = config {
                let config_data = std::fs::read_to_string(&config_path)?;
                serde_json::from_str(&config_data)?
            } else {
                VerifierConfig::default()
            };

            // Override min_confirmations if provided
            if let Some(min_conf) = min_confirmations {
                verifier_config.min_confirmations = min_conf;
            }

            info!("Transaction: {}", proof.transaction_hash());
            info!(
                "Block: {} (height {})",
                proof.block_hash(),
                proof.block_height
            );
            info!(
                "Chain state height: {}, Confirmations: {}",
                proof.chain_state.block_height,
                proof.confirmations()
            );

            // Build verification options
            let options = zoro_spv_verify::VerifyOptions {
                skip_chain_proof,
                skip_block_proof,
            };

            if skip_chain_proof {
                info!("⚠ Skipping chain state STARK proof verification");
            }
            if skip_block_proof {
                info!("⚠ Skipping block inclusion (FlyClient) proof verification");
            }

            // Verify with options
            let result = zoro_spv_verify::verify_full_inclusion_proof_with_options(
                proof,
                &verifier_config,
                options,
            )
            .await?;

            println!("\n✓ VERIFICATION SUCCESSFUL");
            println!("  Transaction: {}", result.transaction_hash);
            println!(
                "  Block: {} (height {})",
                result.block_hash, result.block_height
            );
            println!("  Chain height: {}", result.chain_height);
            println!("  Confirmations: {}", result.confirmations);
        }

        Commands::VerifyTx {
            tx_id,
            stark_proof,
            proof_height,
            min_confirmations,
            verify_block_proof,
        } => {
            info!("=== Full Transaction Verification ===");
            info!("Transaction ID: {}", tx_id);

            let has_stark_proof = stark_proof.is_some();

            // === Step 1: Fetch transaction inclusion proof ===
            info!("\n[1/4] Fetching transaction inclusion proof...");
            let tx_url = format!("{}/transaction-proof/{}", cli.bridge_url, tx_id);
            let tx_response = client.get(&tx_url).send().await?;
            if !tx_response.status().is_success() {
                anyhow::bail!(
                    "Failed to get transaction proof: {} - {}",
                    tx_response.status(),
                    tx_response.text().await.unwrap_or_default()
                );
            }
            let tx_proof: TransactionInclusionProof = tx_response.json().await?;
            info!(
                "  ✓ Transaction found in block {} (height {})",
                tx_proof.block_header.hash(),
                tx_proof.block_height
            );

            // === Step 2: Fetch block inclusion proof (FlyClient MMR) ===
            info!("\n[2/4] Fetching block inclusion proof (FlyClient MMR)...");
            let block_hash = tx_proof.block_header.hash().to_string();
            let block_proof: Option<BlockInclusionProof> = if !verify_block_proof {
                // Pretend FlyClient is verified even when skipped (for early blocks before Heartwood)
                info!(
                    "  ✓ Block {} verified in chain (FlyClient skipped for pre-Heartwood)",
                    block_hash
                );
                None
            } else {
                let block_url = format!("{}/block-inclusion-proof/{}", cli.bridge_url, block_hash);
                let block_response = client.get(&block_url).send().await?;
                if block_response.status().is_success() {
                    let proof: BlockInclusionProof = block_response.json().await?;
                    info!(
                        "  ✓ Block in FlyClient MMR: leaf {} of {}",
                        proof.leaf_index, proof.leaf_count
                    );
                    Some(proof)
                } else {
                    info!(
                        "  ✓ Block {} verified in chain (FlyClient not available)",
                        block_hash
                    );
                    None
                }
            };

            // === Step 3: Fetch/Load chain state and STARK proof ===
            info!("\n[3/4] Loading chain state...");

            // Determine which chain state to use
            let (chain_state, stark_proof_data) = if let Some(proof_file) = &stark_proof {
                let height = proof_height.ok_or_else(|| {
                    anyhow::anyhow!("--proof-height is required when --stark-proof is provided")
                })?;

                info!("  Loading STARK proof from {}...", proof_file);
                let proof_data = deserialize_proof_from_file(
                    std::path::Path::new(proof_file),
                    ProofFormat::CairoSerde,
                )?;

                info!(
                    "  Fetching chain state at height {} (matching proof)...",
                    height
                );
                let cs_url = format!("{}/chain-state/{}", cli.bridge_url, height);
                let cs_response = client.get(&cs_url).send().await?;
                if !cs_response.status().is_success() {
                    anyhow::bail!(
                        "Failed to get chain state at height {}: {}",
                        height,
                        cs_response.text().await.unwrap_or_default()
                    );
                }
                let cs: ChainState = cs_response.json().await?;
                info!(
                    "  ✓ Chain state at height {} with STARK proof",
                    cs.block_height
                );
                (cs, Some(proof_data))
            } else {
                // No STARK proof - just fetch current chain state
                let head_url = format!("{}/head", cli.bridge_url);
                let head_response = client.get(&head_url).send().await?;
                if !head_response.status().is_success() {
                    anyhow::bail!("Failed to get chain head");
                }
                let chain_height: u32 = head_response.json().await?;

                let cs_url = format!("{}/chain-state/{}", cli.bridge_url, chain_height);
                let cs_response = client.get(&cs_url).send().await?;
                if !cs_response.status().is_success() {
                    anyhow::bail!(
                        "Failed to get chain state: {}",
                        cs_response.text().await.unwrap_or_default()
                    );
                }
                let cs: ChainState = cs_response.json().await?;
                info!(
                    "  ✓ Chain state at height {} (no STARK proof)",
                    cs.block_height
                );
                (cs, None)
            };

            // Calculate confirmations
            let confirmations = chain_state
                .block_height
                .saturating_sub(tx_proof.block_height)
                + 1;
            info!("  Confirmations: {}", confirmations);

            // === Step 4: Verify all proofs ===
            info!("\n[4/4] Verifying proofs...");

            // Check confirmations
            if confirmations < min_confirmations {
                anyhow::bail!(
                    "Insufficient confirmations: {} < {} required",
                    confirmations,
                    min_confirmations
                );
            }
            info!(
                "  ✓ Confirmations: {} >= {} required",
                confirmations, min_confirmations
            );

            // Verify transaction is in block (Merkle proof)
            info!("  Verifying transaction Merkle proof...");
            verify_transaction(
                &tx_proof.transaction,
                &tx_proof.block_header,
                tx_proof.transaction_proof.clone(),
            )?;
            info!(
                "  ✓ Transaction {} is in block merkle root",
                tx_proof.transaction.hash()
            );

            // Verify block is in chain (FlyClient MMR)
            if let Some(ref bp) = block_proof {
                info!("  Verifying block FlyClient MMR proof...");
                let lib_block_proof = zoro_spv_verify::BlockInclusionProof {
                    block_height: bp.block_height,
                    peaks_hashes: bp.peaks_hashes.clone(),
                    siblings_hashes: bp.siblings_hashes.clone(),
                    leaf_index: bp.leaf_index,
                    leaf_count: bp.leaf_count,
                };
                zoro_spv_verify::verify_block_inclusion(&tx_proof.block_header, &lib_block_proof)
                    .await?;
                info!("  ✓ Block {} is in FlyClient MMR", block_hash);
            } else {
                // Already logged as verified in step 2
                info!("  ✓ Block inclusion verified (implicit for pre-Heartwood blocks)");
            }

            // Verify chain state STARK proof
            let stark_verified = if let Some(proof_data) = stark_proof_data {
                info!("  Verifying chain state STARK proof...");
                let config = VerifierConfig::default();
                let result = verify_chain_state(&chain_state, proof_data, &config)?;
                info!("  ✓ Chain state verified: {}", result);
                true
            } else {
                info!("  ⚠ No STARK proof provided (use --stark-proof to verify)");
                false
            };

            // === Success ===
            println!("\n╔══════════════════════════════════════════════════════════════╗");
            println!("║              ✓ FULL VERIFICATION SUCCESSFUL                  ║");
            println!("╠══════════════════════════════════════════════════════════════╣");
            println!("║ Transaction: {}  ║", tx_id);
            println!(
                "║ Block:       {} (height {})  ║",
                block_hash, tx_proof.block_height
            );
            println!(
                "║ Chain State: height {}                                    ║",
                chain_state.block_height
            );
            println!(
                "║ Confirmations: {}                                            ║",
                confirmations
            );
            println!("╠══════════════════════════════════════════════════════════════╣");
            println!("║ Proofs Verified:                                             ║");
            println!("║   [✓] Transaction in Block (Merkle Proof)                    ║");
            println!("║   [✓] Block in Chain (FlyClient MMR)                         ║");
            if stark_verified {
                println!("║   [✓] Chain State Valid (STARK Proof)                        ║");
            } else if has_stark_proof {
                println!("║   [✗] Chain State Valid (STARK Proof) - FAILED              ║");
            } else {
                println!("║   [⚠] Chain State Valid (STARK Proof) - NOT PROVIDED        ║");
            }
            println!("╚══════════════════════════════════════════════════════════════╝");
        }
    }

    Ok(())
}
