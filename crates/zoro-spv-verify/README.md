# `zoro-spv-verify` (`spv-cli`)

`zoro-spv-verify` ships a CLI binary called **`spv-cli`** that can:

- **Fetch** Zcash transaction inclusion proofs from a running [`zoro-bridge-node`](../zoro-bridge-node/README.md)
- **Verify** transaction inclusion (Merkle proof)
- Optionally verify:
  - **Block inclusion** via FlyClient MMR proofs (ZIP-221 / `zcash_history`)
  - **Chain state validity** via a **Cairo STARK proof** (produced by [`zoro-assumevalid`](../zoro-assumevalid/README.md))

This is intended as a developer tool for end-to-end SPV verification and for generating/consuming “full inclusion proofs” that bundle all layers into one JSON file.

---

### Prerequisites

- A running **`zoro-bridge-node`** HTTP server (default: `http://127.0.0.1:5000`)
- Rust toolchain (see the repo’s `rust-toolchain.toml`)
- For **STARK chain-state verification**, you also need a Cairo proof JSON produced by `zoro-assumevalid`

---

### Install / build

Run from source:

```bash
cargo run -p zoro-spv-verify --bin spv-cli -- --help
```

Install locally:

```bash
cargo install --path crates/zoro-spv-verify --bin spv-cli
spv-cli --help
```

---

### Bridge node URL

`spv-cli` talks to the bridge node via HTTP. Configure it via:

- `--bridge-url <URL>`
- or `BRIDGE_NODE_URL=<URL>` (default: `http://127.0.0.1:5000`)

Example:

```bash
export BRIDGE_NODE_URL=http://127.0.0.1:5000
```

---

### Quickstart: fetch and verify a transaction proof (Merkle)

Fetch the transaction inclusion proof JSON:

```bash
spv-cli get-proof <TXID_HEX> --output tx_proof.json
```

Fetch + verify immediately:

```bash
spv-cli verify <TXID_HEX>
```

What this verifies:

- The **transaction hash** is included in the block’s **merkle root** (via the returned `transaction_proof`)

What this does **not** verify:

- That the block is on the best chain
- That the chain state is valid / has sufficient work
- That the block is confirmed by an independently verifiable chain tip

For end-to-end verification, use **`verify-tx`** or the “full proof” flow below.

---

### Recommended: verify a transaction end-to-end (`verify-tx`)

`verify-tx` is the “main” verification command. It:

1. Fetches the **transaction proof** (`/transaction-proof/:txid`)
2. Fetches the **chain head** + chain state (for confirmation counting)
3. Verifies the **transaction merkle proof**
4. Optionally verifies:
   - FlyClient **block inclusion** (when `--verify-block-proof` is enabled)
   - Cairo **chain-state STARK proof** (when `--stark-proof` is provided)

Basic usage (merkle proof + confirmation counting against the bridge node’s current head):

```bash
spv-cli verify-tx <TXID_HEX> --min-confirmations 6
```

Enable FlyClient proof verification (Heartwood+ blocks only; see “Notes / limitations”):

```bash
spv-cli verify-tx <TXID_HEX> --min-confirmations 6 --verify-block-proof
```

Add **STARK chain-state verification**:

```bash
spv-cli verify-tx <TXID_HEX> \
  --min-confirmations 6 \
  --stark-proof /path/to/proof.json \
  --proof-height <CHAIN_HEIGHT>
```

Where to get the STARK proof:

- Use [`zoro-assumevalid`](../zoro-assumevalid/README.md) to produce a `proof.json` for a specific height/batch.
- Then pass the proof file + the height it corresponds to via `--stark-proof` and `--proof-height`.

---

### Generate a “full inclusion proof” JSON (`full-proof`)

A “full inclusion proof” bundles three layers into one JSON:

1. **Chain state + STARK proof** (chain tip at height `H`)
2. **FlyClient MMR proof** that the tx’s block is included (block `B`)
3. **Merkle proof** that tx `T` is included in block `B`

Generate it:

```bash
spv-cli full-proof <TXID_HEX> \
  --chain-state-proof /path/to/proof.json \
  --chain-height <H> \
  --output full_proof.json
```

---

### Verify a “full inclusion proof” JSON (`verify-full`)

```bash
spv-cli verify-full full_proof.json
```

Optional flags:

```bash
spv-cli verify-full full_proof.json \
  --min-confirmations 6 \
  --config verifier_config.json
```

Testing-only shortcuts:

```bash
spv-cli verify-full full_proof.json --skip-chain-proof
spv-cli verify-full full_proof.json --skip-block-proof
```

---

### Verify a chain-state STARK proof only (`verify-state`)

This verifies that a Cairo STARK proof matches a chain-state snapshot fetched from the bridge node.

```bash
spv-cli verify-state /path/to/proof.json --height <H>
```

If you have a custom verifier config:

```bash
spv-cli verify-state /path/to/proof.json --height <H> --config verifier_config.json
```

---

### Other useful commands

Fetch chain state:

```bash
spv-cli chain-state <H> --output chain_state.json
```

Fetch a block header:

```bash
spv-cli block-header <H>
```

Get the bridge node’s current head:

```bash
spv-cli head
```

Fetch or verify FlyClient block inclusion proof:

```bash
spv-cli block-proof <BLOCK_HASH_HEX>
spv-cli verify-block <BLOCK_HASH_HEX>
```

---

### Proof formats (JSON)

`spv-cli` consumes/produces JSON using `serde`.

- **Transaction inclusion proof**: returned by bridge node `GET /transaction-proof/:txid`
  - `transaction` (full tx)
  - `transaction_proof` (partial merkle tree / merkle path)
  - `block_header`
  - `block_height`
- **FlyClient block inclusion proof**: returned by bridge node `GET /block-inclusion-proof/:block_hash`
  - `peaks_hashes`, `siblings_hashes`, `leaf_index`, `leaf_count`, `block_height`
- **Chain-state STARK proof**: produced by `zoro-assumevalid` as `proof.json`
  - Must be in **Cairo serde** format (the CLI uses `cairo_air::utils::deserialize_proof_from_file(..., ProofFormat::CairoSerde)`)
- **Full inclusion proof**: produced by `spv-cli full-proof`
  - `chain_state` + `chain_state_proof`
  - `block_header` + `block_inclusion_proof`
  - `transaction` + `transaction_proof`

---

### Verifier config (optional)

Some verification parameters are configurable (bootloader hash, program hash, min confirmations, etc.).
If you pass `--config`, it must be a JSON file matching `VerifierConfig` (see `src/verify.rs`).

Minimal example:

```json
{
  "min_work": "1813388729421943762059264",
  "bootloader_hash": "0x...",
  "task_program_hash": "0x...",
  "task_output_size": 6,
  "min_confirmations": 6
}
```

If you don’t pass `--config`, defaults are used.

---

### Notes / limitations

- **FlyClient availability**: the bridge node’s FlyClient MMR proofs are only available for **Heartwood+** blocks.
- **FlyClient verification completeness**: current `verify_block_inclusion` logic reconstructs an MMR root from peaks and performs basic sanity checks, but it does **not yet** compute and validate the full leaf→root path (see the TODO in `src/verify.rs`).
- **Trust model**:
  - `verify` verifies only **tx-in-block** (merkle root match).
  - `verify-tx` without `--stark-proof` uses the bridge node’s returned chain state/head for confirmation counting, but does **not** cryptographically prove that chain state.
  - Providing a **STARK proof** upgrades chain-state validation to a cryptographic check.


