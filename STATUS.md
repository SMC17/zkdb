# zkdb status

Last green: 2026-08-20 (`zig build test --summary all` — 42/42, Zig 0.16.0, HEAD `e8149bd`)
Visibility: **private** (`SMC17/zkdb`). Do not flip public.

## What this is

Pure-Zig columnar time-series library with q/kdb+-shaped primitives (typed
vectors, asof/window join, q IPC, REPL). Apache-2.0.

Not a production database. No crash recovery, no network server, no auth.

## Persistence (the 7-day cell)

| Piece | Proof level | Evidence |
|-------|-------------|----------|
| `writeColumn` / `readColumn` KJ | `unit-tested` | `src/persist.zig` test `writeColumn readColumn KJ round-trip` |
| `writeColumn` / `readColumn` KF, KI | `compiled` | code in `src/persist.zig`; no dedicated test |
| splay-table / multi-column directory | `sketch` | README roadmap only |
| mmap of column files | `sketch` | `src/persist.zig` module comment says "mmap'd segment files"; I/O is `writeStreamingAll` + `readPositionalAll`. No `mmap` |
| WAL append / replay | `sketch` | README checkbox only. No `Wal` type, no record framing, no CRC, no `fsync` |
| crash recovery | `sketch` | none |

`persist.zig` is a **column-file snapshot** path: `createFile(..., .{ .truncate = true })`, 16-byte `ColHeader` (`magic=0x7A6B`, type, version, count), then packed little-endian elements. That is the opposite of an append-only WAL.

Calling this WAL or mmap would be Type I. Leaving the KJ round-trip uncredited would be Type II.

## Verification

```sh
zig build test --summary all
```

Expected: `42/42 tests passed`. Persist contributes 1 of those 42.

## What is not claimed here

- WAL, mmap, fsync durability, torn-write recovery
- Splay-table directories or symbol-column files
- Any DuckDB / QuestDB / ClickHouse ratio (not re-measured this gate)
- Public release

## 7-day cell

See [NEXT.md](NEXT.md). Open register: `exp-1787259851-219371427`.
Inspection that WAL/mmap do not exist: `exp-1787259851-088183692` confirmed.
