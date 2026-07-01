//! wj — window join with comptime aggregation lambdas.
//!
//! For each left row (sym_l[i], ts_l[i]), collect all right rows r where:
//!   sym_r[r] == sym_l[i]  AND  ts_l[i] - window_ns <= ts_r[r] <= ts_l[i]
//! Then apply an aggregation function to the right data column over that window.
//!
//! The aggregation is comptime-parametric: callers pass a comptime function
//! to specialize the inner loop at build time. No closures, no vtable.
//!
//! Built-in aggregations: sum, avg, last, first, count, min, max.

const std = @import("std");
const asof = @import("asof.zig");

// Per-symbol sorted index into the right table.
const SymIdx = struct {
    ts: []const i64,
    rows: []usize,  // row indices sorted by ts
};

fn buildIndex(
    allocator: std.mem.Allocator,
    sym_r: []const u32,
    ts_r: []const i64,
) !std.AutoHashMap(u32, SymIdx) {
    // Group right rows by sym
    var groups = std.AutoHashMap(u32, std.array_list.Managed(usize)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        groups.deinit();
    }

    for (0..sym_r.len) |i| {
        const g = try groups.getOrPut(sym_r[i]);
        if (!g.found_existing) g.value_ptr.* = std.array_list.Managed(usize).init(allocator);
        try g.value_ptr.append(i);
    }

    var idx = std.AutoHashMap(u32, SymIdx).init(allocator);

    var it = groups.iterator();
    while (it.next()) |entry| {
        const sym = entry.key_ptr.*;
        const row_list = entry.value_ptr.items;

        // Sort by ts
        const rows = try allocator.dupe(usize, row_list);
        std.mem.sort(usize, rows, ts_r, struct {
            fn lessThan(ctx: []const i64, a: usize, b: usize) bool {
                return ctx[a] < ctx[b];
            }
        }.lessThan);

        const ts_sorted = try allocator.alloc(i64, rows.len);
        for (rows, 0..) |r, i| ts_sorted[i] = ts_r[r];

        try idx.put(sym, .{ .ts = ts_sorted, .rows = rows });
    }

    return idx;
}

/// windowRange: return [lo, hi) row-index span in a sorted right array
/// where right.ts in [t - window_ns, t].
fn windowRange(ts_sorted: []const i64, t: i64, window_ns: i64) struct { lo: usize, hi: usize } {
    const lo_ts = t - window_ns;
    // lower bound: first index where ts >= lo_ts
    var lo: usize = 0;
    var hi_lo: usize = ts_sorted.len;
    while (lo < hi_lo) {
        const mid = lo + (hi_lo - lo) / 2;
        if (ts_sorted[mid] < lo_ts) lo = mid + 1 else hi_lo = mid;
    }
    // upper bound: last index where ts <= t (first > t)
    var hi: usize = lo;
    var hi_hi: usize = ts_sorted.len;
    while (hi < hi_hi) {
        const mid = hi + (hi_hi - hi) / 2;
        if (ts_sorted[mid] <= t) hi = mid + 1 else hi_hi = mid;
    }
    return .{ .lo = lo, .hi = hi };
}

/// wjAgg: window join with comptime aggregation function.
///
/// agg_fn(data: []const T, rows: []const usize, lo: usize, hi: usize) T
/// Called with a slice of the right data column and the window row span [lo, hi).
///
/// Returns one aggregated value per left row.
pub fn wjAgg(
    comptime T: type,
    comptime agg_fn: fn ([]const T, []const usize, usize, usize) T,
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
    data_r: []const T,
    window_ns: i64,
) ![]T {
    const idx = try buildIndex(allocator, sym_r, ts_r);
    defer {
        var it = idx.iterator();
        while (it.next()) |e| {
            allocator.free(e.value_ptr.ts);
            allocator.free(e.value_ptr.rows);
        }
        var mutable_idx = idx;
        mutable_idx.deinit();
    }

    const out = try allocator.alloc(T, sym_l.len);
    @memset(out, 0);

    for (sym_l, 0..) |sym, i| {
        const t = ts_l[i];
        const entry = idx.get(sym) orelse continue;
        const range = windowRange(entry.ts, t, window_ns);
        out[i] = agg_fn(data_r, entry.rows, range.lo, range.hi);
    }

    return out;
}

// ---- Built-in aggregation functions ----

pub fn aggSum(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(data: []const T, rows: []const usize, lo: usize, hi: usize) T {
            var s: T = 0;
            for (rows[lo..hi]) |r| s += data[r];
            return s;
        }
    }.f;
}

pub fn aggAvg(data: []const f64, rows: []const usize, lo: usize, hi: usize) f64 {
    if (hi <= lo) return std.math.nan(f64);
    var s: f64 = 0.0;
    for (rows[lo..hi]) |r| s += data[r];
    return s / @as(f64, @floatFromInt(hi - lo));
}

pub fn aggLast(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(data: []const T, rows: []const usize, lo: usize, hi: usize) T {
            if (hi <= lo) return 0;
            return data[rows[hi - 1]];
        }
    }.f;
}

pub fn aggFirst(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(data: []const T, rows: []const usize, lo: usize, hi: usize) T {
            if (hi <= lo) return 0;
            return data[rows[lo]];
        }
    }.f;
}

pub fn aggCount(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(_: []const T, _: []const usize, lo: usize, hi: usize) T {
            return @intCast(hi - lo);
        }
    }.f;
}

pub fn aggMin(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(data: []const T, rows: []const usize, lo: usize, hi: usize) T {
            if (hi <= lo) return 0;
            var m = data[rows[lo]];
            for (rows[lo + 1..hi]) |r| if (data[r] < m) { m = data[r]; };
            return m;
        }
    }.f;
}

pub fn aggMax(comptime T: type) fn ([]const T, []const usize, usize, usize) T {
    return struct {
        fn f(data: []const T, rows: []const usize, lo: usize, hi: usize) T {
            if (hi <= lo) return 0;
            var m = data[rows[lo]];
            for (rows[lo + 1..hi]) |r| if (data[r] > m) { m = data[r]; };
            return m;
        }
    }.f;
}

// ---- High-level typed wrappers for common aggregations ----

/// wjSumF64: sum of f64 right column over time window per left row.
pub fn wjSumF64(
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
    data_r: []const f64,
    window_ns: i64,
) ![]f64 {
    return wjAgg(f64, aggSum(f64), allocator, sym_l, ts_l, sym_r, ts_r, data_r, window_ns);
}

/// wjAvgF64: avg of f64 right column over time window per left row.
pub fn wjAvgF64(
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
    data_r: []const f64,
    window_ns: i64,
) ![]f64 {
    return wjAgg(f64, aggAvg, allocator, sym_l, ts_l, sym_r, ts_r, data_r, window_ns);
}

/// wjLastF64: last f64 value in window per left row.
pub fn wjLastF64(
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
    data_r: []const f64,
    window_ns: i64,
) ![]f64 {
    return wjAgg(f64, aggLast(f64), allocator, sym_l, ts_l, sym_r, ts_r, data_r, window_ns);
}

test "wjSumF64 basic" {
    const alloc = std.testing.allocator;

    // 2 syms: 0=AAPL, 1=GOOG
    const sym_l = [_]u32{ 0, 0, 1 };
    const ts_l  = [_]i64{ 1000, 2000, 1500 };

    // Right: AAPL quotes at ts 100,500,900,1200,1800; GOOG at 800,1200
    const sym_r  = [_]u32{ 0,  0,  0,  0,   0,   1,   1 };
    const ts_r   = [_]i64{ 100,500,900,1200,1800, 800, 1200 };
    const price_r= [_]f64{ 1.0,2.0,3.0,4.0,5.0,10.0,20.0 };

    // window = 1000ns; for ts_l[0]=1000: right rows [100..1000] → ts 100,500,900 → sum=6
    const result = try wjSumF64(alloc, &sym_l, &ts_l, &sym_r, &ts_r, &price_r, 1000);
    defer alloc.free(result);

    try std.testing.expectApproxEqAbs(6.0, result[0], 1e-9);  // 1+2+3
    // ts_l[1]=2000: window [1000..2000] → ts 1200,1800 → sum=9
    try std.testing.expectApproxEqAbs(9.0, result[1], 1e-9);  // 4+5
    // ts_l[2]=1500, GOOG: window [500..1500] → ts 800,1200 → sum=30
    try std.testing.expectApproxEqAbs(30.0, result[2], 1e-9); // 10+20
}

test "wjAvgF64 basic" {
    const alloc = std.testing.allocator;
    const sym_l = [_]u32{ 0 };
    const ts_l  = [_]i64{ 1000 };
    const sym_r  = [_]u32{ 0, 0, 0 };
    const ts_r   = [_]i64{ 100, 500, 900 };
    const price_r= [_]f64{ 2.0, 4.0, 6.0 };

    const result = try wjAvgF64(alloc, &sym_l, &ts_l, &sym_r, &ts_r, &price_r, 1000);
    defer alloc.free(result);

    try std.testing.expectApproxEqAbs(4.0, result[0], 1e-9);
}

test "wjLastF64 basic" {
    const alloc = std.testing.allocator;
    const sym_l = [_]u32{ 0 };
    const ts_l  = [_]i64{ 1000 };
    const sym_r  = [_]u32{ 0, 0, 0 };
    const ts_r   = [_]i64{ 100, 500, 900 };
    const price_r= [_]f64{ 2.0, 4.0, 6.0 };

    const result = try wjLastF64(alloc, &sym_l, &ts_l, &sym_r, &ts_r, &price_r, 1000);
    defer alloc.free(result);

    // Last right row in window [0..1000] for AAPL is ts=900 price=6.0
    try std.testing.expectApproxEqAbs(6.0, result[0], 1e-9);
}
