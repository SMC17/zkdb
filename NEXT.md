# NEXT — zkdb 7-day cell

WAL + mmap. Do **not** start a fake WAL. Do **not** flip public.

## Why this is a rewrite, not a stub test

`src/persist.zig` (156 lines) is snapshot column I/O:

- Header: 16-byte `ColHeader` (`MAGIC 0x7A6B`, `type_code`, `VERSION 1`, `count`)
- `writeColumn`: truncate-create, stream KJ/KF/KI
- `readColumn`: positional read, allocate a new `K` vector
- One test: KJ round-trip

There is no append log, no CRC, no `fsync`, no replay cursor, no mmap, no
checkpoint. `tests/` is empty; tests live as `test` blocks in `src/*.zig`.
A happy-path "write bytes, read bytes" file is not WAL.

## Exact files

| File | Role in the cell |
|------|------------------|
| `src/wal.zig` | **new**. `Wal` type: framed append, `fsync`, replay, torn-tail skip |
| `src/persist.zig` | keep as snapshot splay path; do not overload it into a log. Fix the mmap comment only when mmap actually lands |
| `src/root.zig` | `pub const wal = @import("wal.zig");` and `_ = @import("wal.zig");` in the test graph |
| `src/types.zig` | `K` union the payload may serialize (KJ/KF/KI first, same as persist) |
| `build.zig` | unchanged if tests stay in `src/wal.zig` (root already `addTest`s `src/root.zig`) |

Out of scope for this cell: query planner, IPC, REPL, Elixir NIF, DuckDB benches.

## Exact falsifier

Register: `exp-1787259851-219371427` (lane `zkdb`, proof `unit-tested`).

`zig build test` must include a test that:

1. Opens a temp WAL, appends **N = 100** framed records.
   Frame (suggested, little-endian): `u32 magic` + `u8 type` + `u32 len` +
   `u32 crc32` + `payload[len]`. CRC covers `type || len || payload`.
2. `fsync`s after the last append.
3. Truncates the file so the **last** record is cut mid-payload (torn write).
4. Reopens and **replays**:
   - recovers **exactly 99** records
   - payloads equal the first 99 appended values
   - the torn tail is skipped (not returned, not a crash)
5. A second case: flip one byte in record 50's payload; replay detects CRC
   failure at that record and does not silently yield a corrupt payload.

Refuted if any of: happy-path-only append/read with no torn tail; no CRC;
no `fsync`; test count of intact records ≠ 99; corrupt payload returned as
valid; `zig build test` red.

## mmap (same 7-day window, second falsifier)

Only after WAL replay is green:

- Map a persist column file after `writeColumn` of N KJ values.
- `readColumn` (or a new `mapColumn`) returns a view whose `[]i64` matches
  the written slice **without** a per-element positional loop.
- Falsifier: checksum/equality fails, or the read path still uses
  `readPositionalAll` per element.

Proof level today: **sketch** (comment only). Do not claim `scaffold` until
a mapping API exists.

## Proof levels (do not promote early)

| Claim | Level now | Promotes to `unit-tested` when |
|-------|-----------|--------------------------------|
| persist KJ snapshot I/O | `unit-tested` | already |
| WAL | `sketch` | falsifier above is green |
| mmap | `sketch` | mmap falsifier above is green |
| crash recovery | `sketch` | torn-tail + CRC cases green |

## Constraints

- Keep `zig build test` at ≥ 42/42 while adding WAL tests.
- Do not replace persist's 16-byte `ColHeader` format.
- Do not invent engine-comparison numbers.
- Do not force-push `main`. Do not flip GitHub public.
- Apache-2.0.
