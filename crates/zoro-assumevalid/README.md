# `zoro-assumevalid`

`zoro-assumevalid` is a **binary tool** that fetches Zcash chain data from a running `zoro-bridge-node`, runs the `assumevalid` Cairo program through the bootloader, and produces **STARK proofs** for **Zcash block headers** in batches.

This crate is **not intended to be consumed as a Rust library**. (There is some internal library code to keep the binary organized, but the supported interface is the CLI.)

## What it does

- **Fetches chain state** at a starting height from `zoro-bridge-node`
- **Fetches Zcash block headers** for a range `(start_height+1 .. start_height+block_count)`
- **Generates Cairo runner arguments** (including Equihash indices + sorted-indices hints)
- **Runs the Cairo executable via the bootloader** in proof mode
- **Generates and writes a proof** to disk (`proof.json`) for each batch
- **Resumes automatically** by scanning an output directory for prior batches

## Prerequisites

- **Rust toolchain** (see the repo’s `rust-toolchain.toml`)
- A reachable **`zoro-bridge-node` HTTP endpoint** providing:
  - `GET /head`
  - `GET /chain-state/{height}`
  - `GET /headers?offset={offset}&size={size}`

## Build & run

### Run from source (recommended for development)

```bash
cargo run -p zoro-assumevalid -- prove --total-blocks 100 --step-size 10
```

### Build a release binary

```bash
cargo build -p zoro-assumevalid --release
./target/release/zoro-assumevalid prove --total-blocks 100 --step-size 10
```

## CLI usage

### `prove` (iterative batch proving)

Prove a total number of blocks in batches. The tool determines the **starting height automatically** by scanning the output directory for existing `batch_*_to_*` folders and continuing from the highest end height.

```bash
# Use the default bridge URL (currently https://staging.zoro.wtf) and write into ./.proofs
zoro-assumevalid prove --total-blocks 100 --step-size 10

# Point at a local bridge node, enable debug logs, and choose an output directory
zoro-assumevalid --bridge-url http://127.0.0.1:5000 --log-level debug \
  prove --total-blocks 1000 --step-size 25 --output-dir .proofs
```

### Overriding the Cairo executable / prover params

```bash
zoro-assumevalid prove \
  --executable crates/zoro-assumevalid/compiled/assumevalid.executable.json \
  --prover-params-file packages/assumevalid/prover_params.json \
  --total-blocks 100 --step-size 10
```

### Keeping temporary files

By default, each batch writes `arguments.json` and removes it after the proof succeeds. To keep it:

```bash
zoro-assumevalid prove --keep-temp-files --total-blocks 10 --step-size 1
```

### Notes on GCS flags

The CLI currently accepts `--load-from-gcs`, `--save-to-gcs`, and `--gcs-bucket`, but the current implementation does **not** upload/download proofs yet (the tool still resumes by scanning the local output directory).

## Output layout

For each batch, the tool creates a directory:

- `OUTPUT_DIR/batch_{start}_to_{start+step}/proof.json`

Example:

- `.proofs/batch_0_to_10/proof.json`
- `.proofs/batch_10_to_20/proof.json`

## License

See the repo’s top-level `LICENSE`.
