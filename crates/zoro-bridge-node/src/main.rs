#![doc = include_str!("../README.md")]

use std::path::PathBuf;

use clap::{command, Parser};
use tokio::task::JoinHandle;
use tracing::{error, info, subscriber::set_global_default};
use tracing_subscriber::filter::EnvFilter;

use crate::{
    indexer::{Indexer, IndexerConfig},
    rpc::{RpcConfig, RpcServer},
    shutdown::Shutdown,
};

mod chain_state;
mod indexer;
mod rpc;
mod shutdown;
mod store;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
struct Cli {
    /// RPC server host
    #[arg(long, default_value = "127.0.0.1:5000")]
    rpc_host: String,
    /// Zcash RPC URL
    #[arg(long, env = "ZCASH_RPC")]
    zcash_rpc_url: String,
    /// Zcash RPC user:password (optional)
    #[arg(long, env = "USERPWD")]
    zcash_rpc_userpwd: Option<String>,
    /// Path to the database storing the app state
    #[arg(long, default_value = "./.data/app.db")]
    db_path: PathBuf,
    /// ID
    #[arg(long, default_value = "blocks")]
    id: String,
    /// Indexing lag in blocks, to address potential reorgs
    #[arg(long, default_value = "1")]
    block_lag: u32,
    /// Logging level (off, error, warn, info, debug, trace)
    #[arg(long, default_value = "info")]
    log_level: String,
}

fn init_tracing(log_level: &str) {
    let env_filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(log_level));

    let subscriber_builder =
        tracing_subscriber::fmt::Subscriber::builder().with_env_filter(env_filter);

    let subscriber = subscriber_builder.with_writer(std::io::stderr).finish();
    set_global_default(subscriber).expect("Failed to set subscriber");
}

#[tokio::main]
async fn main() {
    // Load environment variables from .env file if it exists
    dotenv::dotenv().ok();

    let cli = Cli::parse();
    init_tracing(&cli.log_level);

    info!("Zoro bridge node is launching...");

    // Instantiating components and wiring them together
    let shutdown = Shutdown::default();

    let indexer_config = IndexerConfig {
        rpc_url: cli.zcash_rpc_url.clone(),
        rpc_userpwd: cli.zcash_rpc_userpwd.clone(),
        id: cli.id.clone(),
        db_path: cli.db_path.clone(),
        indexing_lag: cli.block_lag,
    };
    let mut indexer = Indexer::new(indexer_config, shutdown.subscribe());

    let rpc_config = RpcConfig {
        rpc_host: cli.rpc_host,
        id: cli.id,
        db_path: cli.db_path.clone(),
        rpc_url: cli.zcash_rpc_url.clone(),
        rpc_userpwd: cli.zcash_rpc_userpwd.clone(),
    };
    let rpc_server = RpcServer::new(rpc_config, shutdown.subscribe());

    // Launching threads for each component
    let indexer_handle = tokio::spawn(async move { indexer.run().await });
    let rpc_handle = tokio::spawn(async move { rpc_server.run().await });
    let shutdown_handle = tokio::spawn(async move { shutdown.run().await });

    // If at least one component exits with an error, the node will exit with an error
    match tokio::try_join!(
        flatten(indexer_handle),
        flatten(rpc_handle),
        flatten(shutdown_handle)
    ) {
        Ok(_) => {
            info!("Zoro bridge node has shut down");
            std::process::exit(0);
        }
        Err(_) => {
            error!("Zoro bridge node has exited with error");
            std::process::exit(1);
        }
    }
}

async fn flatten<T>(handle: JoinHandle<Result<T, ()>>) -> Result<T, ()> {
    match handle.await {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(err)) => Err(err),
        Err(_) => Err(()),
    }
}
