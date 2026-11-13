# zkdb status

| | |
|---|---|
| Proof level | **unit-tested** (see [proof levels](https://github.com/SMC17/SMC17/blob/main/STANDARDS.md#proof-levels)) |
| Last verified | 2026-11-12, fresh clone, macOS on Apple M2 Max, Zig 0.16.0 |
| Command | `zig build test --summary all` |
| Result | 50/50 tests pass |

## What this is

A pure-Zig columnar time-series library with q/kdb+-shaped primitives: typed vectors, SIMD aggregation, asof and window joins, q IPC and a REPL. Apache-2.0.

It is not a production database: no crash recovery, no network server, no authentication.

## Persistence

| Piece | Proof level | Evidence |
|---|---|---|
| Column files (`writeColumn` / `readColumn`) for KJ, KI, KF | unit-tested | `src/persist.zig` round-trip and malformed-input tests; `zig build demo` writes, closes, reopens and sums a column |
| Splay tables / multi-column directories | sketch | Roadmap only |
| Memory-mapped column files | sketch | Not implemented; I/O is positional read and write |
| Atomic column writes | unit-tested | Temp file, fsync, rename over the target; test simulates a crash before the rename |
| Payload checksum (CRC32, format v2) | unit-tested | Flipped payload byte is rejected; v1 files still read |
| Directory fsync after rename, write-ahead log | sketch | Not implemented: power loss right after a write can lose that write, not corrupt the file |

Column files are snapshots: each write builds a complete new file beside the old one and renames it into place, with a 16-byte header (format v2 carries a CRC32 of the payload) and packed little-endian values. A crash leaves the previous file or the new one. It is not an append-only log.

## Not claimed

- Durability of the most recent write across power loss (no directory fsync)
- Splay tables or symbol-column files
- Any comparison with DuckDB, QuestDB, ClickHouse or kdb+
