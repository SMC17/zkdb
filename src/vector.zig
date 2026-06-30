//! vector — typed columnar arrays with SIMD aggregation.
//!
//! Each numeric verb (sum, min, max, avg, prd) is SIMD-dispatched via
//! @Vector. Width is chosen at comptime to match the element type:
//!   f64/i64 → Vec(4)   (256-bit AVX2 lane)
//!   f32/i32 → Vec(8)
//!   i16     → Vec(16)
//!   bool/u8 → Vec(32)
//!
//! Scalar fallback handles the remainder after SIMD lanes.
//!
//! This is the core disproof of the "multiple years" claim: Zig comptime
//! generates all type-specialized kernels from a single generic; kdb+
//! hand-codes each in C.

const std = @import("std");

fn simdWidth(comptime T: type) comptime_int {
    return switch (@sizeOf(T)) {
        8 => 4,
        4 => 8,
        2 => 16,
        1 => 32,
        else => 1,
    };
}

pub fn sum(comptime T: type, items: []const T) T {
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = 0;
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        acc += @reduce(.Add, v);
    }
    while (i < items.len) : (i += 1) acc += items[i];
    return acc;
}

pub fn sumF(comptime T: type, items: []const T) T {
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = 0.0;
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        acc += @reduce(.Add, v);
    }
    while (i < items.len) : (i += 1) acc += items[i];
    return acc;
}

pub fn min(comptime T: type, items: []const T) T {
    if (items.len == 0) return std.math.maxInt(T);
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = items[0];
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        const m = @reduce(.Min, v);
        if (m < acc) acc = m;
    }
    while (i < items.len) : (i += 1) {
        if (items[i] < acc) acc = items[i];
    }
    return acc;
}

pub fn minF(comptime T: type, items: []const T) T {
    if (items.len == 0) return std.math.inf(T);
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = items[0];
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        const m = @reduce(.Min, v);
        if (m < acc) acc = m;
    }
    while (i < items.len) : (i += 1) {
        if (items[i] < acc) acc = items[i];
    }
    return acc;
}

pub fn max(comptime T: type, items: []const T) T {
    if (items.len == 0) return std.math.minInt(T);
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = items[0];
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        const m = @reduce(.Max, v);
        if (m > acc) acc = m;
    }
    while (i < items.len) : (i += 1) {
        if (items[i] > acc) acc = items[i];
    }
    return acc;
}

pub fn maxF(comptime T: type, items: []const T) T {
    if (items.len == 0) return -std.math.inf(T);
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = items[0];
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        const m = @reduce(.Max, v);
        if (m > acc) acc = m;
    }
    while (i < items.len) : (i += 1) {
        if (items[i] > acc) acc = items[i];
    }
    return acc;
}

pub fn prd(comptime T: type, items: []const T) T {
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = 1;
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        acc *= @reduce(.Mul, v);
    }
    while (i < items.len) : (i += 1) acc *= items[i];
    return acc;
}

pub fn avg(comptime T: type, items: []const T) f64 {
    if (items.len == 0) return std.math.nan(f64);
    return @as(f64, @floatFromInt(sum(T, items))) / @as(f64, @floatFromInt(items.len));
}

pub fn avgF(comptime T: type, items: []const T) f64 {
    if (items.len == 0) return std.math.nan(f64);
    return @as(f64, sumF(T, items)) / @as(f64, @floatFromInt(items.len));
}

// Equality mask: returns bitmap of matching indices. Used by where-clause.
pub fn eqMask(comptime T: type, allocator: std.mem.Allocator, items: []const T, val: T) ![]bool {
    const mask = try allocator.alloc(bool, items.len);
    for (items, 0..) |x, i| mask[i] = (x == val);
    return mask;
}

// Greater-than mask
pub fn gtMask(comptime T: type, allocator: std.mem.Allocator, items: []const T, val: T) ![]bool {
    const mask = try allocator.alloc(bool, items.len);
    for (items, 0..) |x, i| mask[i] = (x > val);
    return mask;
}

// Less-than mask
pub fn ltMask(comptime T: type, allocator: std.mem.Allocator, items: []const T, val: T) ![]bool {
    const mask = try allocator.alloc(bool, items.len);
    for (items, 0..) |x, i| mask[i] = (x < val);
    return mask;
}

// Apply boolean mask to a slice, return filtered copy.
pub fn applyMask(comptime T: type, allocator: std.mem.Allocator, items: []const T, mask: []const bool) ![]T {
    var count: usize = 0;
    for (mask) |b| { if (b) count += 1; }
    const out = try allocator.alloc(T, count);
    var j: usize = 0;
    for (items, 0..) |x, i| {
        if (mask[i]) { out[j] = x; j += 1; }
    }
    return out;
}

// AND two boolean masks in-place (a &= b).
pub fn andMask(a: []bool, b: []const bool) void {
    for (a, 0..) |*x, i| { x.* = x.* and b[i]; }
}

// Collect indices where mask is true.
pub fn whereTrue(allocator: std.mem.Allocator, mask: []const bool) ![]usize {
    var count: usize = 0;
    for (mask) |b| { if (b) count += 1; }
    const out = try allocator.alloc(usize, count);
    var j: usize = 0;
    for (mask, 0..) |b, i| {
        if (b) { out[j] = i; j += 1; }
    }
    return out;
}

test "sum i64 SIMD" {
    const items = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(i64, 55), sum(i64, &items));
}

test "sum f64 SIMD" {
    const items = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    try std.testing.expectApproxEqAbs(15.0, sumF(f64, &items), 1e-9);
}

test "min max i32" {
    const items = [_]i32{ 5, -3, 9, 1, 0, 7 };
    try std.testing.expectEqual(@as(i32, -3), min(i32, &items));
    try std.testing.expectEqual(@as(i32, 9), max(i32, &items));
}

test "avg f64" {
    const items = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    try std.testing.expectApproxEqAbs(3.0, avgF(f64, &items), 1e-9);
}

test "mask and filter" {
    const items = [_]i32{ 1, 5, 3, 8, 2, 9 };
    const mask = try gtMask(i32, std.testing.allocator, &items, 4);
    defer std.testing.allocator.free(mask);
    const filtered = try applyMask(i32, std.testing.allocator, &items, mask);
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualSlices(i32, &.{ 5, 8, 9 }, filtered);
}
