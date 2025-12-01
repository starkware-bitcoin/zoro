<div align="center">
  <img src="./docs/img/zoro.png" alt="zoro-logo" height="260"/>

  ***ZK client for Zcash written in Cairo. Inspired by [Raito](https://github.com/keep-starknet-strange/raito).***

  <a href="https://z.cash/">
    <img alt="Zcash" src="https://img.shields.io/badge/Zcash-000?style=for-the-badge&logo=zcash&logoColor=white" height=30>
  </a>
  <a href="https://www.cairo-lang.org/">
    <img alt="Cairo" src="https://img.shields.io/badge/Cairo-000?style=for-the-badge" height=30>
  </a>
</div>

---

## Overview

**Zoro** is a ZK client for Zcash, implemented in Cairo. It enables **succinct, verifiable execution of Zcash consensus rules** using STARK proofs.

Zoro can validate Zcash blocks and produce a cryptographic proof that this execution was correct. The result is a compressible and trust-minimized client — useful for bridges, syncing, L2s, or privacy-preserving systems that rely on Zcash validity.

Like [Raito](https://github.com/starkware-bitcoin/raito) does for Bitcoin, Zoro provides the same features but for Zcash.
> **Note:** Early-stage prototype. Expect rapid iteration.

In general STARKs can be very useful to the Zcash ecosystem.

Another unlock they could provide (assuming a change in the base layer) is unlocking ZK rollups on top of Zcash.

If you want to know more about this, check those resources:

- [Ztarknet proposal on the Zcash community forum - a Starknet L2 for Zcash](https://forum.zcashcommunity.com/t/proposal-ztarknet-a-starknet-l2-for-zcash/)
- [STARK verification as a Transparent Zcash Extension (TZE), i.e. enabler for a Starknet‑style L2 on Zcash.](https://forum.zcashcommunity.com/t/stark-verification-as-a-transparent-zcash-extension-tze-i-e-enabler-for-a-starknet-style-l2-on-zcash)
- [Why Cairo / FAQ and concerns / security, blockspace footprint, etc](https://forum.zcashcommunity.com/t/why-cairo-starks-for-ztarknet-and-stark-verify-tze/)
- Ztarknet POC website: <https://ztarknet.cash>

---

## Name Reference

Zoro is a reference to **Roronoa Zoro**, the swordsman from *One Piece*.

- He fights blindfolded, yet never misses.
- He follows his own code, never swayed by noise.
- He masters multiple blades — just like Zoro wields multiple Zcash consensus rules.

---

## Quick Start

```bash
make build  # build Zoro client
make test  # run Zoro tests
```

## Objective

**Build and publish “Zoro”: a zero‑knowledge light client for Zcash implemented in Cairo that produces succinct STARK receipts for Zcash chain validity.**
A Zoro receipt attests, for a contiguous block range, that:

1. **Headers form a valid chain** (linking, timestamps, difficulty/target adherence) and satisfy **Equihash (n=200, k=9)** proof‑of‑work checks.
2. The chain’s **FlyClient / MMR commitment** is correctly maintained, i.e., the computed `hashChainHistoryRoot` (ZIP‑221) matches the header commitment (post‑activation).
3. For each block in the range, the **transaction commitments** are consistent with the v5 digest rules (ZIP‑244): we recompute the block’s `hashMerkleRoot` from `txid_digest`s and the **authorizing‑data Merkle root** (`hashAuthDataRoot`), and then the linked **`hashBlockCommitments`** value committed in the header.

**Design constraint:** Zoro does **not** change Zcash. It is an external prover/verifier pair and a set of Cairo programs + tooling. The outputs are portable receipts that other systems can verify off‑chain, or (optionally, later) *on Zcash itself* if the community adopts a STARK verifier via the TZE mechanism (ZIP‑222 + ZIP‑245).

## Why this is useful

* **Compressed SPV & cross‑chain proofs.** A single 50–200 KiB‑scale receipt can cover thousands of headers. That enables practical verification of Zcash history on other chains, and efficient bridges/relays that only need to check a STARK once instead of streaming headers. (Exact sizes to be reported from benchmarks; the verifier is hash‑heavy and predictable, priced by bytes.)
* **Trust‑minimized light clients.** Mobile or constrained clients can accept Zoro receipts instead of trusting a server for header/commitment correctness. FlyClient’s MMR in headers was added for this class of use cases; Zoro makes those proofs *succinct* and aggregatable.
* **Clean interface to L2 / applications.** Zoro gives Ztarknet (Starknet‑style L2) and other consumers a canonical, succinct statement about L1 state (best‑chain tip, MMR root, block commitments) without L1 churn. If the **`STARK_VERIFY_V1` TZE** is adopted, the reverse also becomes possible: L1 can verify STARK receipts/claims (e.g., L2 exits) in consensus.
* **Engineering leverage from Raito.** Raito already implements a Bitcoin consensus client in Cairo and a recursive STARK pipeline. Zoro reuses the same methodology (and some Cairo components such as Script), while adapting to **Zcash‑specific header, digest, and commitment rules** (ZIP‑221/244/245).

## What Zoro proves

Let `B_i..B_j` be a contiguous chain segment ending at height `j`. Zoro’s STARK proves:

**H. Headers & PoW**

* `hashPrevBlock(B_k) = H(B_{k-1})` for `k = i+1..j`.
* Difficulty/target rules and median‑time checks per consensus.
* **Equihash (n=200, k=9)** solution in each header is valid and the header hash ≤ `ToTarget(nBits)`, with solution size 1344 bytes (spec §7.5 header layout).

**C. Chain‑history MMR (FlyClient)**

* We recompute the **MMR node structure and metadata** specified by ZIP‑221 over `[x..k-1]` for each `B_k` (activation boundary `x` per ZIP‑221).
* For `B_j`, the **`hashChainHistoryRoot`** we compute equals the value used inside **`hashBlockCommitments`** in the block header. (ZIP‑221 + ZIP‑244 renaming/semantics).

**T. Block transaction commitments**

* For each block, we parse v5 transactions and recompute:

  * the tree‑structured **`txid_digest`** (ZIP‑244 §TxId Digest),
  * the **authorizing‑data commitment** tree and its Merkle root **`hashAuthDataRoot`** (ZIP‑244 §Authorizing Data Commitment, §Block Header Changes), and
  * the linked‑list hash **`hashBlockCommitments = H( hashLightClientRoot, hashAuthDataRoot, terminator )`** in the header (ZIP‑244 §Block Header Changes).
    We then check equality to the header field.

> **Note on shielded verification scope.** In Milestones 0–2 (below), we **do not re‑verify** Sapling/Orchard zk‑proofs inside the STARK. Instead, we recompute and check the **header‑committed digests** that bind *authorizing data* (including proofs and signatures) and *txids*, per ZIP‑244. Later milestones explore adding selected shielded invariants (nullifier uniqueness checks and treestate updates) and, if feasible, in‑STARK verification of Orchard/Halo2 receipts.

## Architecture & toolchain

**Language / VM.** Cairo (zk‑native ISA).
**Prover.** Stwo (Circle‑STARKs) with recursion for long ranges.
**Verifier(s).**

1. Native Rust verifier for off‑chain consumers;
2. Optional **TZE verifier** profile (if the community adopts `STARK_VERIFY_V1` as a Transparent Zcash Extension per ZIP‑222/245). The TZE variant is the same proof format with pinned params and byte caps; the extension returns a boolean inside consensus. 

**Inputs.** Raw blocks from `zcashd`/`zebra`; we build witness data (headers, tx component digests per ZIP‑244, and MMR metadata per ZIP‑221).

**Outputs (receipt).** For a proved range:

* `tip_hash`, `tip_height`, cumulative work,
* `hashBlockCommitments(tip)`, `hashChainHistoryRoot(tip)`,
* (optionally) sub‑proofs for subranges (via recursion) and inclusion proofs for blocks/txs.

## Specification dependencies (normative)

* **ZIP‑221 FlyClient / `hashChainHistoryRoot`** and the exact MMR metadata (inc. Sapling/Orchard root/count commitments). Zoro follows the node layout and hashing personalization as specified.
* **ZIP‑244 v5 digests** (`txid_digest`, `auth_digest`) and **`hashBlockCommitments`** definition (linked list over `hashLightClientRoot` and `hashAuthDataRoot`).
* **ZIP‑245** (TxID and signature digest changes to include TZE branches) — relevant if/when we add TZE inputs/outputs to tests or use a TZE profile.
* **ZIP‑222 Transparent Zcash Extensions** — for the optional in‑consensus verification path (`STARK_VERIFY_V1`).
* **Protocol spec** sections for **Equihash** and header fields (solution size, PoW hashing/difficulty).

## Work plan & milestones

**Milestone 0 — Header‑chain proof (core SPV)**

* Cairo programs for header parsing, linking, median‑time, target/retarget, Equihash (200,9) verification, and cumulative work.
* Circle‑STARK proof for ranges (e.g., 2^k headers) with recursion; receipt and verifier.
  **Deliverables:** CLI that proves `B_i..B_j` and verifies; unit tests against `zcashd`/`zebra` canonical chains; PoW test vectors.

**Milestone 1 — FlyClient MMR (ZIP‑221)**

* Implement MMR node construction and hashing (personalized BLAKE2b‑256), recompute `hashChainHistoryRoot`, and check equality with the header’s `hashBlockCommitments` component.
  **Deliverables:** proofs that the MMR root at `B_j` matches the header‑committed value; inclusion proofs for arbitrary earlier block ranges using the Zoro receipt.

**Milestone 2 — v5 transaction & block commitments (ZIP‑244)**

* Full re‑implementation (in Cairo) of `txid_digest` tree and **authorizing‑data commitment** tree; per‑block recomputation of `hashMerkleRoot` and `hashAuthDataRoot`; recompute **`hashBlockCommitments`** and check header equality.
* Transparent‑only sanity checks (sum of input/output values where available; see ZIP‑244 transparent amounts/scripts digests).
  **Deliverables:** receipts that bind the block’s txids and authorizing data to the header via `hashBlockCommitments`.

**Milestone 3 — Public shielded invariants (bounded scope)**

* Parse Sapling/Orchard components and enforce *public* consistency checks that are verifiable without re‑running the zk‑proofs:

  * nullifier uniqueness per block (no duplicates),
  * treestate anchoring consistency across blocks using the MMR‑committed `hash{Earliest,Latest}{Sapling,Orchard}Root` metadata,
  * transaction‑level balance fields where publicly checkable.
    **Deliverables:** receipts additionally guaranteeing no‑duplicate‑nullifiers in proved ranges and treestate‑root consistency per ZIP‑221 metadata.

**Milestone 4 — Recursive aggregation & APIs**

* Stable recursive pipeline to “roll up” long ranges into one receipt; JSON/Protobuf APIs for wallets, bridges, and L2s; Rust verifier crate.

**Milestone 5 — Feasibility R&D (optional)**

* Explore in‑STARK verification of **Orchard/Halo2 receipts** (engineering spike only), or, alternatively, **proof‑carrying data** approaches where nodes emit compact validity receipts that Zoro verifies. (This item will be reported back with measurements and a go/no‑go recommendation.)

> **Non‑goals:** any change to shielded pool semantics; any change to the block header or transaction formats; any reliance on external DA layers.

## Interfaces & expected consumers

* **Wallets / light clients:** ask a server (or peer) for a Zoro receipt covering `[h−Δ..h]` plus Merkle branch for specific tx; verify locally and accept with SPV‑plus guarantees. (The receipt contains the MMR root for FlyClient‑style subproofs.)
* **Bridges / relays:** verify a single receipt instead of streaming headers; on EVM/Starknet, use native STARK verifiers or precompiles.
* **Ztarknet (L2):** anchor to Zcash in two ways: (a) L2 posts its own STARK to Zcash via the **TZE verifier** (if adopted), and (b) L2 trusts *Zcash state* using Zoro receipts provided by independent parties, avoiding a full node in the prover.

## Relationship to prior and parallel efforts

* **Raito (Bitcoin):** methodology and libraries for header‑chain proofs, recursive composition; Zoro is the Zcash analogue with Zcash‑specific commitments and PoW.
* **ZIP‑221/244/245:** Zoro is explicitly aligned with these ZIPs (MMR in headers; v5 tx digests; `hashBlockCommitments`); the Cairo code will mirror those specs and ship test vectors cross‑checked against `zcashd`/`zebra`.
* **`STARK_VERIFY` TZE:** orthogonal; Zoro works without it, but the TZE would enable **in‑consensus** use (e.g., L2 exits, on‑chain challenges).

## License

This project is licensed under [MIT](LICENSE).