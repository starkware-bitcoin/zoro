<div align="center">
  <img src="./docs/img/zoro.png" alt="zoro-logo" height="260"/>

  ***ZK client for Zcash written in Cairo. Inspired by [Raito](https://github.com/keep-starknet-strange/raito).***

  <a href="https://github.com/starkware-bitcoin/zoro/actions/workflows/build.yml">
    <img alt="GitHub Workflow Status" src="https://img.shields.io/github/actions/workflow/status/ztarknet/zoro/check.yml?style=for-the-badge" height=30>
  </a>
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

---

## Name Reference

Zoro is a reference to **Roronoa Zoro**, the swordsman from *One Piece*.

- He fights blindfolded, yet never misses.
- He follows his own code, never swayed by noise.
- He masters multiple blades — just like Zoro wields multiple Zcash consensus rules.

---

## Quick Start

```bash
scarb build      # compile the Zoro Cairo packages
scarb test       # run Zoro tests
```

## License

This project is licensed under [MIT](LICENSE).