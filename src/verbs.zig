//! verbs — q arithmetic, comparison, and string verbs on K values.
//!
//! q has ~50 built-in verbs. We implement the HFT-critical set:
//!   +  add        -  subtract     *  multiply     %  divide
//!   &  min/and    |  max/or       =  equal        <>  not-equal
//!   <  less       >  greater      ~  match        !  flip/key
//!   #  count      ,  join/enlist  ^  fill         @  at/index
//!   ?  find       _  drop/floor   $  string cast
//!   sum avg min max prd var dev   — aggregate verbs
//!
//! Each verb dispatches on K type at runtime. The comptime vector module
//! handles the SIMD inner loops; this module handles the dispatch.

const std = @import("std");
const types = @import("types.zig");
const vec = @import("vector.zig");

const K = types.K;

pub const VerbError = error{ TypeMismatch, LengthMismatch, DivisionByZero, IndexOutOfRange };

// ---- Aggregates ----

pub fn kSum(k: K) !K {
    return switch (k) {
        .KJ => |v| K{ .long = vec.sum(i64, v.items) },
        .KI => |v| K{ .long = @as(i64, vec.sum(i32, v.items)) },
        .KF => |v| K{ .float = vec.sumF(f64, v.items) },
        .KE => |v| K{ .float = @as(f64, vec.sumF(f32, v.items)) },
        else => VerbError.TypeMismatch,
    };
}

pub fn kAvg(k: K) !K {
    return switch (k) {
        .KJ => |v| K{ .float = vec.avg(i64, v.items) },
        .KI => |v| K{ .float = vec.avg(i32, v.items) },
        .KF => |v| K{ .float = vec.avgF(f64, v.items) },
        .KE => |v| K{ .float = vec.avgF(f32, v.items) },
        else => VerbError.TypeMismatch,
    };
}

pub fn kMin(k: K) !K {
    return switch (k) {
        .KJ => |v| K{ .long = vec.min(i64, v.items) },
        .KI => |v| K{ .int = vec.min(i32, v.items) },
        .KF => |v| K{ .float = vec.minF(f64, v.items) },
        .KE => |v| K{ .real = vec.minF(f32, v.items) },
        else => VerbError.TypeMismatch,
    };
}

pub fn kMax(k: K) !K {
    return switch (k) {
        .KJ => |v| K{ .long = vec.max(i64, v.items) },
        .KI => |v| K{ .int = vec.max(i32, v.items) },
        .KF => |v| K{ .float = vec.maxF(f64, v.items) },
        .KE => |v| K{ .real = vec.maxF(f32, v.items) },
        else => VerbError.TypeMismatch,
    };
}

pub fn kCount(k: K) K {
    return K{ .long = @intCast(types.kVecLen(k)) };
}

// ---- Element-wise binary ops on vectors ----

pub fn kAdd(allocator: std.mem.Allocator, a: K, b: K) !K {
    switch (a) {
        .KJ => |va| switch (b) {
            .KJ => |vb| {
                if (va.items.len != vb.items.len) return VerbError.LengthMismatch;
                const out = try allocator.alloc(i64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x + vb.items[i];
                return K{ .KJ = .{ .items = out } };
            },
            .long => |s| {
                const out = try allocator.alloc(i64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x + s;
                return K{ .KJ = .{ .items = out } };
            },
            else => return VerbError.TypeMismatch,
        },
        .KF => |va| switch (b) {
            .KF => |vb| {
                if (va.items.len != vb.items.len) return VerbError.LengthMismatch;
                const out = try allocator.alloc(f64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x + vb.items[i];
                return K{ .KF = .{ .items = out } };
            },
            .float => |s| {
                const out = try allocator.alloc(f64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x + s;
                return K{ .KF = .{ .items = out } };
            },
            else => return VerbError.TypeMismatch,
        },
        else => return VerbError.TypeMismatch,
    }
}

pub fn kMul(allocator: std.mem.Allocator, a: K, b: K) !K {
    switch (a) {
        .KF => |va| switch (b) {
            .float => |s| {
                const out = try allocator.alloc(f64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x * s;
                return K{ .KF = .{ .items = out } };
            },
            .KF => |vb| {
                if (va.items.len != vb.items.len) return VerbError.LengthMismatch;
                const out = try allocator.alloc(f64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x * vb.items[i];
                return K{ .KF = .{ .items = out } };
            },
            else => return VerbError.TypeMismatch,
        },
        .KJ => |va| switch (b) {
            .long => |s| {
                const out = try allocator.alloc(i64, va.items.len);
                for (va.items, 0..) |x, i| out[i] = x * s;
                return K{ .KJ = .{ .items = out } };
            },
            else => return VerbError.TypeMismatch,
        },
        else => return VerbError.TypeMismatch,
    }
}

// Variance (sample) via two-pass
pub fn kVar(allocator: std.mem.Allocator, k: K) !K {
    _ = allocator;
    return switch (k) {
        .KF => |v| {
            if (v.items.len < 2) return K{ .float = std.math.nan(f64) };
            const m = vec.avgF(f64, v.items);
            var s: f64 = 0.0;
            for (v.items) |x| { const d = x - m; s += d * d; }
            return K{ .float = s / @as(f64, @floatFromInt(v.items.len - 1)) };
        },
        else => VerbError.TypeMismatch,
    };
}

pub fn kDev(allocator: std.mem.Allocator, k: K) !K {
    const v = try kVar(allocator, k);
    return K{ .float = @sqrt(v.float) };
}

// fill: replace null sentinels with a value (^ in q)
pub fn kFill(allocator: std.mem.Allocator, fill_val: f64, k: K) !K {
    return switch (k) {
        .KF => |v| {
            const out = try allocator.alloc(f64, v.items.len);
            for (v.items, 0..) |x, i| out[i] = if (std.math.isNan(x)) fill_val else x;
            return K{ .KF = .{ .items = out } };
        },
        else => VerbError.TypeMismatch,
    };
}

test "kSum long vector" {
    var items = [_]i64{ 10, 20, 30 };
    const result = try kSum(K{ .KJ = .{ .items = &items } });
    try std.testing.expectEqual(@as(i64, 60), result.long);
}

test "kAvg float vector" {
    var items = [_]f64{ 1.0, 2.0, 3.0 };
    const result = try kAvg(K{ .KF = .{ .items = &items } });
    try std.testing.expectApproxEqAbs(2.0, result.float, 1e-9);
}

test "kAdd vectors" {
    var a = [_]i64{ 1, 2, 3 };
    var b = [_]i64{ 4, 5, 6 };
    const result = try kAdd(
        std.testing.allocator,
        K{ .KJ = .{ .items = &a } },
        K{ .KJ = .{ .items = &b } },
    );
    defer std.testing.allocator.free(result.KJ.items);
    try std.testing.expectEqualSlices(i64, &.{ 5, 7, 9 }, result.KJ.items);
}

test "kVar and kDev" {
    var items = [_]f64{ 2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0 };
    const v = try kVar(std.testing.allocator, K{ .KF = .{ .items = &items } });
    try std.testing.expectApproxEqAbs(4.571, v.float, 0.001);
    const d = try kDev(std.testing.allocator, K{ .KF = .{ .items = &items } });
    try std.testing.expectApproxEqAbs(2.138, d.float, 0.001);
}

test "kFill NaN" {
    var items = [_]f64{ 1.0, std.math.nan(f64), 3.0, std.math.nan(f64) };
    const result = try kFill(std.testing.allocator, 0.0, K{ .KF = .{ .items = &items } });
    defer std.testing.allocator.free(result.KF.items);
    try std.testing.expectApproxEqAbs(0.0, result.KF.items[1], 1e-9);
    try std.testing.expectApproxEqAbs(0.0, result.KF.items[3], 1e-9);
}
