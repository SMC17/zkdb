# zkdb status

| | |
|---|---|
| Proof level | **unit-tested** (see [proof levels](https://github.com/SMC17/SMC17/blob/main/STANDARDS.md#proof-levels)) |
| Last verified | 2026-11-12, fresh clone, macOS on Apple M2 Max, Zig 0.16.0 |
| Command | `zig build test --summary all` |
| Result | 47/47 tests pass |

## What this is

A pure-Zig columnar time-series library with q/kdb+-shaped primitives: typed vectors, SIMD aggregation, asof and window joins, q IPC and a REPL. Apache-2.0.

It is not a production database: no crash recovery, no network server, no authentication.

## Persistence

| Piece | Proof level | Evidence |
|---|---|---|
| Column files (`writeColumn` / `readColumn`) for KJ, KI, KF | unit-tested | `src/persist.zig` round-trip and malformed-input tests; `zig build demo` writes, closes, reopens and sums a column |
| Splay tables / multi-column directories | sketch | Roadmap only |
| Memory-mapped column files | sketch | Not implemented; I/O is positional read and write |
| Write-ahead log, fsync durability, crash recovery | sketch | Not implemented ([#3](https://github.com/SMC17/zkdb/issues/3)) |

Column files are snapshots: a file is truncated and rewritten with a 16-byte header and packed little-endian values. That is not an append-only log, and nothing here should be read as crash-safe.

## Not claimed

- Durability of any kind beyond a clean close and reopen
- Splay tables or symbol-column files
- Any comparison with DuckDB, QuestDB, ClickHouse or kdb+
