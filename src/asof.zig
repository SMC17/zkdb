//! asof — time-series join primitives.
//!
//! aj (asof join): For each row in the left table, find the last row in
//! the right table where right.time <= left.time (and optionally keyed by
//! symbol). This is the core kdb+/q primitive for tick data.
//!
//! Complexity: O(n log m) — binary search per left row.
//!
//! wj (window join): For each left row, aggregate right rows in [t-w, t].
//!
//! Both assume right table is sorted ascending by timestamp.

const std = @import("std");

pub const NO_MATCH: usize = std.math.maxInt(usize);

/// asofSearch: last index i where right_ts[i] <= t. NO_MATCH if none.
pub fn asofSearch(right_ts: []const i64, t: i64) usize {
    if (right_ts.len == 0 or t < right_ts[0]) return NO_MATCH;
    var lo: usize = 0;
    var hi: usize = right_ts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (right_ts[mid] <= t) lo = mid else hi = mid;
    }
    return lo;
}

/// aj0: Simple asof join (no keying by symbol). O(n) using monotone cursor.
pub fn aj0(
    allocator: std.mem.Allocator,
    left_ts: []const i64,
    right_ts: []const i64,
) ![]usize {
    const result = try allocator.alloc(usize, left_ts.len);
    var r: usize = 0;
    for (left_ts, 0..) |t, i| {
        while (r + 1 < right_ts.len and right_ts[r + 1] <= t) r += 1;
        result[i] = if (right_ts.len > 0 and right_ts[0] <= t) r else NO_MATCH;
    }
    return result;
}

const SymTsRow = struct { ts: i64, idx: usize };

/// aj: Keyed asof join by symbol. O(n log m).
pub fn aj(
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
) ![]usize {
    std.debug.assert(sym_l.len == ts_l.len);
    std.debug.assert(sym_r.len == ts_r.len);

    var sym_map = std.AutoHashMap(u32, std.array_list.Managed(SymTsRow)).init(allocator);
    defer {
        var it = sym_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        sym_map.deinit();
    }

    for (sym_r, 0..) |sym, i| {
        const entry = try sym_map.getOrPut(sym);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.array_list.Managed(SymTsRow).init(allocator);
        }
        try entry.value_ptr.append(.{ .ts = ts_r[i], .idx = i });
    }

    const result = try allocator.alloc(usize, sym_l.len);
    for (sym_l, 0..) |sym, i| {
        const t = ts_l[i];
        if (sym_map.get(sym)) |rows| {
            const items = rows.items;
            if (items.len == 0 or t < items[0].ts) {
                result[i] = NO_MATCH;
            } else {
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo + 1 < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid].ts <= t) lo = mid else hi = mid;
                }
                result[i] = items[lo].idx;
            }
        } else {
            result[i] = NO_MATCH;
        }
    }
    return result;
}

/// wjCount: Window join — count right rows in [t - window_ns, t] per left row.
pub fn wjCount(
    allocator: std.mem.Allocator,
    sym_l: []const u32,
    ts_l: []const i64,
    sym_r: []const u32,
    ts_r: []const i64,
    window_ns: i64,
) ![]usize {
    std.debug.assert(sym_l.len == ts_l.len);
    std.debug.assert(sym_r.len == ts_r.len);

    var sym_map = std.AutoHashMap(u32, std.array_list.Managed(SymTsRow)).init(allocator);
    defer {
        var it = sym_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        sym_map.deinit();
    }

    for (sym_r, 0..) |sym, i| {
        const entry = try sym_map.getOrPut(sym);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.array_list.Managed(SymTsRow).init(allocator);
        }
        try entry.value_ptr.append(.{ .ts = ts_r[i], .idx = i });
    }

    const result = try allocator.alloc(usize, sym_l.len);
    for (sym_l, 0..) |sym, i| {
        const t = ts_l[i];
        const lo_t = t - window_ns;
        if (sym_map.get(sym)) |rows| {
            const items = rows.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid].ts < lo_t) lo = mid + 1 else hi = mid;
            }
            const start = lo;
            hi = items.len;
            lo = start;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid].ts <= t) lo = mid else hi = mid;
            }
            result[i] = if (items.len > start and items[start].ts <= t)
                lo - start + 1
            else
                0;
        } else {
            result[i] = 0;
        }
    }
    return result;
}

test "asofSearch" {
    const ts = [_]i64{ 100, 200, 300, 400, 500 };
    try std.testing.expectEqual(NO_MATCH, asofSearch(&ts, 50));
    try std.testing.expectEqual(@as(usize, 0), asofSearch(&ts, 100));
    try std.testing.expectEqual(@as(usize, 1), asofSearch(&ts, 250));
    try std.testing.expectEqual(@as(usize, 4), asofSearch(&ts, 999));
}

test "aj0 simple" {
    const left_ts = [_]i64{ 150, 250, 350, 50 };
    const right_ts = [_]i64{ 100, 200, 300 };
    const result = try aj0(std.testing.allocator, &left_ts, &right_ts);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result[0]);
    try std.testing.expectEqual(@as(usize, 1), result[1]);
    try std.testing.expectEqual(@as(usize, 2), result[2]);
    try std.testing.expectEqual(NO_MATCH, result[3]);
}

test "aj keyed by symbol" {
    const sym_l = [_]u32{ 0, 1, 0 };
    const ts_l = [_]i64{ 150, 250, 350 };
    const sym_r = [_]u32{ 0, 1, 0 };
    const ts_r = [_]i64{ 100, 200, 300 };

    const result = try aj(std.testing.allocator, &sym_l, &ts_l, &sym_r, &ts_r);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result[0]);
    try std.testing.expectEqual(@as(usize, 1), result[1]);
    try std.testing.expectEqual(@as(usize, 2), result[2]);
}

test "wjCount window join" {
    const sym_l = [_]u32{ 0, 0 };
    const ts_l = [_]i64{ 300, 500 };
    const sym_r = [_]u32{ 0, 0, 0, 0 };
    const ts_r = [_]i64{ 100, 200, 300, 400 };

    const result = try wjCount(std.testing.allocator, &sym_l, &ts_l, &sym_r, &ts_r, 150);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result[0]);
    try std.testing.expectEqual(@as(usize, 1), result[1]);
}
