//! query — select/update/delete/exec evaluation.
//!
//! Maps q's four functional forms:
//!   select [cols] from t where conds
//!   update col:expr from t where conds
//!   delete from t where conds
//!   exec col from t where conds   (returns vector, not table)
//!
//! We implement a typed predicate DSL that avoids runtime string parsing:
//! callers build Predicate values and pass them to select/update/delete.
//! This gives compile-time type safety and zero parse overhead on hot paths.

const std = @import("std");
const types = @import("types.zig");
const vec = @import("vector.zig");

const K = types.K;
const Table = types.Table;

// A row index bitmap — callers can AND multiple predicates.
pub const Bitmap = []bool;

// Predicate tag for the typed DSL.
pub const PredTag = enum { gt_i64, lt_i64, eq_i64, gt_f64, lt_f64, eq_f64, eq_sym };

pub const Predicate = struct {
    col: []const u8,
    tag: PredTag,
    vi64: i64 = 0,
    vf64: f64 = 0.0,
    vsym: u32 = 0,
};

/// eval_pred: compute a row boolean mask for one predicate against a table.
pub fn evalPred(
    allocator: std.mem.Allocator,
    table: *const Table,
    pred: Predicate,
) !Bitmap {
    const col = table.columns.get(pred.col) orelse return error.ColumnNotFound;
    const n = types.kVecLen(col);
    const mask = try allocator.alloc(bool, n);
    @memset(mask, false);

    switch (pred.tag) {
        .gt_i64 => switch (col) {
            .KJ => |v| for (v.items, 0..) |x, i| { mask[i] = x > pred.vi64; },
            .KI => |v| for (v.items, 0..) |x, i| { mask[i] = @as(i64, x) > pred.vi64; },
            .KP => |v| for (v.items, 0..) |x, i| { mask[i] = x > pred.vi64; },
            .KT => |v| for (v.items, 0..) |x, i| { mask[i] = @as(i64, x) > pred.vi64; },
            else => return error.TypeMismatch,
        },
        .lt_i64 => switch (col) {
            .KJ => |v| for (v.items, 0..) |x, i| { mask[i] = x < pred.vi64; },
            .KI => |v| for (v.items, 0..) |x, i| { mask[i] = @as(i64, x) < pred.vi64; },
            .KP => |v| for (v.items, 0..) |x, i| { mask[i] = x < pred.vi64; },
            else => return error.TypeMismatch,
        },
        .eq_i64 => switch (col) {
            .KJ => |v| for (v.items, 0..) |x, i| { mask[i] = x == pred.vi64; },
            .KI => |v| for (v.items, 0..) |x, i| { mask[i] = @as(i64, x) == pred.vi64; },
            else => return error.TypeMismatch,
        },
        .gt_f64 => switch (col) {
            .KF => |v| for (v.items, 0..) |x, i| { mask[i] = x > pred.vf64; },
            .KE => |v| for (v.items, 0..) |x, i| { mask[i] = @as(f64, x) > pred.vf64; },
            else => return error.TypeMismatch,
        },
        .lt_f64 => switch (col) {
            .KF => |v| for (v.items, 0..) |x, i| { mask[i] = x < pred.vf64; },
            .KE => |v| for (v.items, 0..) |x, i| { mask[i] = @as(f64, x) < pred.vf64; },
            else => return error.TypeMismatch,
        },
        .eq_f64 => switch (col) {
            .KF => |v| for (v.items, 0..) |x, i| { mask[i] = x == pred.vf64; },
            else => return error.TypeMismatch,
        },
        .eq_sym => switch (col) {
            .KS => |v| for (v.items, 0..) |x, i| { mask[i] = x == pred.vsym; },
            else => return error.TypeMismatch,
        },
    }
    return mask;
}

/// andPreds: compute the AND of multiple predicates.
pub fn andPreds(
    allocator: std.mem.Allocator,
    table: *const Table,
    preds: []const Predicate,
) !Bitmap {
    if (preds.len == 0) {
        const n = table.rowCount();
        const mask = try allocator.alloc(bool, n);
        @memset(mask, true);
        return mask;
    }
    const first = try evalPred(allocator, table, preds[0]);
    for (preds[1..]) |p| {
        const m = try evalPred(allocator, table, p);
        defer allocator.free(m);
        vec.andMask(first, m);
    }
    return first;
}

// Project a column through a row-index list.
fn projectCol(allocator: std.mem.Allocator, col: K, rows: []const usize) !K {
    return switch (col) {
        .KJ => |v| blk: {
            const out = try allocator.alloc(i64, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KJ = .{ .items = out } };
        },
        .KI => |v| blk: {
            const out = try allocator.alloc(i32, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KI = .{ .items = out } };
        },
        .KF => |v| blk: {
            const out = try allocator.alloc(f64, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KF = .{ .items = out } };
        },
        .KE => |v| blk: {
            const out = try allocator.alloc(f32, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KE = .{ .items = out } };
        },
        .KS => |v| blk: {
            const out = try allocator.alloc(u32, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KS = .{ .items = out } };
        },
        .KP => |v| blk: {
            const out = try allocator.alloc(i64, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KP = .{ .items = out } };
        },
        .KB => |v| blk: {
            const out = try allocator.alloc(bool, rows.len);
            for (rows, 0..) |r, i| out[i] = v.items[r];
            break :blk K{ .KB = .{ .items = out } };
        },
        else => error.UnsupportedType,
    };
}

/// selectFrom: materialise a new Table with only the given columns and rows
/// matching the AND of all predicates.
/// cols: null means all columns.
pub fn selectFrom(
    allocator: std.mem.Allocator,
    src: *const Table,
    cols: ?[]const []const u8,
    preds: []const Predicate,
) !Table {
    const mask = try andPreds(allocator, src, preds);
    defer allocator.free(mask);
    const rows = try vec.whereTrue(allocator, mask);
    defer allocator.free(rows);

    var dst = Table.init(allocator);
    errdefer dst.deinit();

    if (cols) |col_names| {
        for (col_names) |name| {
            const col = src.columns.get(name) orelse return error.ColumnNotFound;
            const projected = try projectCol(allocator, col, rows);
            try dst.columns.put(name, projected);
        }
    } else {
        var it = src.columns.iterator();
        while (it.next()) |entry| {
            const projected = try projectCol(allocator, entry.value_ptr.*, rows);
            try dst.columns.put(entry.key_ptr.*, projected);
        }
    }
    return dst;
}

/// deleteFrom: return new Table with matching rows removed.
pub fn deleteFrom(
    allocator: std.mem.Allocator,
    src: *const Table,
    preds: []const Predicate,
) !Table {
    const mask = try andPreds(allocator, src, preds);
    defer allocator.free(mask);
    // Invert mask
    for (mask) |*b| b.* = !b.*;
    const rows = try vec.whereTrue(allocator, mask);
    defer allocator.free(rows);

    var dst = Table.init(allocator);
    errdefer dst.deinit();

    var it = src.columns.iterator();
    while (it.next()) |entry| {
        const projected = try projectCol(allocator, entry.value_ptr.*, rows);
        try dst.columns.put(entry.key_ptr.*, projected);
    }
    return dst;
}

test "select with predicate" {
    // Use arena so all projected column slices are freed together.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prices = [_]f64{ 100.0, 200.0, 150.0, 300.0, 50.0 };
    var syms = [_]u32{ 0, 1, 0, 1, 0 };

    var t = Table.init(allocator);
    defer t.deinit();
    try t.columns.put("price", K{ .KF = .{ .items = &prices } });
    try t.columns.put("sym", K{ .KS = .{ .items = &syms } });

    const preds = [_]Predicate{
        .{ .col = "price", .tag = .gt_f64, .vf64 = 120.0 },
    };

    var result = try selectFrom(allocator, &t, null, &preds);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.rowCount());
}

test "delete with predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prices = [_]f64{ 100.0, 200.0, 150.0, 300.0 };

    var t = Table.init(allocator);
    defer t.deinit();
    try t.columns.put("price", K{ .KF = .{ .items = &prices } });

    const preds = [_]Predicate{
        .{ .col = "price", .tag = .gt_f64, .vf64 = 150.0 },
    };

    var result = try deleteFrom(allocator, &t, &preds);
    defer result.deinit();

    // Rows with price > 150 deleted: only 100.0 and 150.0 remain
    try std.testing.expectEqual(@as(usize, 2), result.rowCount());
}
