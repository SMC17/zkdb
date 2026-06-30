//! ipc — q IPC binary protocol (de)serialization.
//!
//! Wire format (little-endian):
//!   Byte 0: endian (1 = little)
//!   Byte 1: msg type (0=async 1=sync 2=response)
//!   Byte 2: compression (0 = none)
//!   Byte 3: reserved
//!   Bytes 4-7: total message length including header (u32 LE)
//!   Body: serialized K object
//!
//! K object layout:
//!   Byte 0: type code (i8) — negative atom, positive vector, 0 list
//!   Byte 1: attributes (0=none)
//!   Then per type:
//!     atoms: raw bytes for the value
//!     vectors: u32 count, then packed values
//!     list: u32 count, then serialized K objects
//!     dict: serialize keys K, then values K
//!     table: type 98, serialize a dict of col-name-list → col-value-list
//!
//! Type codes: 1=KB 4=KG 5=KH 6=KI 7=KJ 8=KE 9=KF 10=KC 11=KS 12=KP
//!             14=KD 16=KT 0=list 99=dict 98=table
//!
//! Symbol serialization: null-terminated UTF-8 bytes.

const std = @import("std");
const types = @import("types.zig");

const K = types.K;
const Table = types.Table;

pub const MsgType = enum(u8) { async_ = 0, sync = 1, response = 2 };

pub const Header = packed struct {
    endian: u8 = 1, // little-endian
    msg_type: u8,
    compressed: u8 = 0,
    reserved: u8 = 0,
    len: u32, // total bytes incl. header
};

pub const HEADER_SIZE: usize = 8;

// ---- Serialization ----

pub const Writer = std.array_list.Managed(u8);

fn writeU8(w: *Writer, v: u8) !void { try w.append(v); }
fn writeI8(w: *Writer, v: i8) !void { try w.append(@bitCast(v)); }
fn writeU32(w: *Writer, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try w.appendSlice(&buf);
}
fn writeI32(w: *Writer, v: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, v, .little);
    try w.appendSlice(&buf);
}
fn writeI64(w: *Writer, v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .little);
    try w.appendSlice(&buf);
}
fn writeF32(w: *Writer, v: f32) !void {
    var buf: [4]u8 = undefined;
    const bits: u32 = @bitCast(v);
    std.mem.writeInt(u32, &buf, bits, .little);
    try w.appendSlice(&buf);
}
fn writeF64(w: *Writer, v: f64) !void {
    var buf: [8]u8 = undefined;
    const bits: u64 = @bitCast(v);
    std.mem.writeInt(u64, &buf, bits, .little);
    try w.appendSlice(&buf);
}
fn writeSymStr(w: *Writer, s: []const u8) !void {
    try w.appendSlice(s);
    try w.append(0); // null terminator
}

pub fn serializeK(w: *Writer, k: K, sym_names: ?[]const []const u8) !void {
    switch (k) {
        // Atoms
        .boolean => |v| { try writeI8(w, -1); try writeU8(w, 0); try writeU8(w, if (v) 1 else 0); },
        .byte => |v| { try writeI8(w, -4); try writeU8(w, 0); try writeU8(w, v); },
        .short => |v| { try writeI8(w, -5); try writeU8(w, 0);
            var buf: [2]u8 = undefined; std.mem.writeInt(i16, &buf, v, .little); try w.appendSlice(&buf); },
        .int => |v| { try writeI8(w, -6); try writeU8(w, 0); try writeI32(w, v); },
        .long => |v| { try writeI8(w, -7); try writeU8(w, 0); try writeI64(w, v); },
        .real => |v| { try writeI8(w, -8); try writeU8(w, 0); try writeF32(w, v); },
        .float => |v| { try writeI8(w, -9); try writeU8(w, 0); try writeF64(w, v); },
        .char => |v| { try writeI8(w, -10); try writeU8(w, 0); try writeU8(w, v); },
        .symbol => |v| {
            try writeI8(w, -11); try writeU8(w, 0);
            const name: []const u8 = if (sym_names) |n| n[v] else "?";
            try writeSymStr(w, name);
        },
        .timestamp => |v| { try writeI8(w, -12); try writeU8(w, 0); try writeI64(w, v); },
        .date => |v| { try writeI8(w, -14); try writeU8(w, 0); try writeI32(w, v); },
        .time => |v| { try writeI8(w, -16); try writeU8(w, 0); try writeI32(w, v); },
        // Vectors
        .KB => |v| {
            try writeI8(w, 1); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeU8(w, if (x) 1 else 0);
        },
        .KG => |v| {
            try writeI8(w, 4); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            try w.appendSlice(v.items);
        },
        .KH => |v| {
            try writeI8(w, 5); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| { var buf: [2]u8 = undefined; std.mem.writeInt(i16, &buf, x, .little); try w.appendSlice(&buf); }
        },
        .KI => |v| {
            try writeI8(w, 6); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeI32(w, x);
        },
        .KJ => |v| {
            try writeI8(w, 7); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeI64(w, x);
        },
        .KE => |v| {
            try writeI8(w, 8); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeF32(w, x);
        },
        .KF => |v| {
            try writeI8(w, 9); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeF64(w, x);
        },
        .KC => |v| {
            try writeI8(w, 10); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            try w.appendSlice(v.items);
        },
        .KS => |v| {
            try writeI8(w, 11); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| {
                const name: []const u8 = if (sym_names) |n| n[x] else "?";
                try writeSymStr(w, name);
            }
        },
        .KP => |v| {
            try writeI8(w, 12); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeI64(w, x);
        },
        .KD => |v| {
            try writeI8(w, 14); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeI32(w, x);
        },
        .KT => |v| {
            try writeI8(w, 16); try writeU8(w, 0); try writeU32(w, @intCast(v.items.len));
            for (v.items) |x| try writeI32(w, x);
        },
        .list => |v| {
            try writeI8(w, 0); try writeU8(w, 0); try writeU32(w, @intCast(v.len));
            for (v) |item| try serializeK(w, item, sym_names);
        },
        .dict => |d| {
            try writeU8(w, 99);
            try serializeK(w, d.keys.*, sym_names);
            try serializeK(w, d.values.*, sym_names);
        },
        .table => |t| {
            // Table = flip of dict. Wire: type 98, then a dict of
            // char-vector-of-names → mixed-list-of-vectors.
            try writeU8(w, 98);
            try writeU8(w, 0); // table attributes
            // Inner dict
            try writeU8(w, 99);
            // Keys: symbol vector of column names
            try writeI8(w, 11); // KS
            try writeU8(w, 0);
            try writeU32(w, @intCast(t.columns.count()));
            var it = t.columns.iterator();
            while (it.next()) |entry| try writeSymStr(w, entry.key_ptr.*);
            // Values: mixed list of column vectors
            try writeI8(w, 0); // list
            try writeU8(w, 0);
            try writeU32(w, @intCast(t.columns.count()));
            it = t.columns.iterator();
            while (it.next()) |entry| try serializeK(w, entry.value_ptr.*, sym_names);
        },
    }
}

pub fn frameMessage(allocator: std.mem.Allocator, body: []const u8, msg_type: MsgType) ![]u8 {
    const total: u32 = @intCast(HEADER_SIZE + body.len);
    var out = try allocator.alloc(u8, total);
    out[0] = 1; // little-endian
    out[1] = @intFromEnum(msg_type);
    out[2] = 0;
    out[3] = 0;
    std.mem.writeInt(u32, out[4..8], total, .little);
    @memcpy(out[8..], body);
    return out;
}

// ---- Deserialization ----

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn readU8(self: *Reader) !u8 {
        if (self.pos >= self.buf.len) return error.EndOfBuffer;
        defer self.pos += 1;
        return self.buf[self.pos];
    }
    pub fn readI8(self: *Reader) !i8 { return @bitCast(try self.readU8()); }
    pub fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.buf.len) return error.EndOfBuffer;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
    }
    pub fn readI32(self: *Reader) !i32 {
        if (self.pos + 4 > self.buf.len) return error.EndOfBuffer;
        defer self.pos += 4;
        return std.mem.readInt(i32, self.buf[self.pos..][0..4], .little);
    }
    pub fn readI64(self: *Reader) !i64 {
        if (self.pos + 8 > self.buf.len) return error.EndOfBuffer;
        defer self.pos += 8;
        return std.mem.readInt(i64, self.buf[self.pos..][0..8], .little);
    }
    pub fn readF32(self: *Reader) !f32 {
        if (self.pos + 4 > self.buf.len) return error.EndOfBuffer;
        defer self.pos += 4;
        const bits = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        return @bitCast(bits);
    }
    pub fn readF64(self: *Reader) !f64 {
        if (self.pos + 8 > self.buf.len) return error.EndOfBuffer;
        defer self.pos += 8;
        const bits = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        return @bitCast(bits);
    }
    // Read null-terminated string; returns slice into buf.
    pub fn readSym(self: *Reader) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != 0) self.pos += 1;
        if (self.pos >= self.buf.len) return error.EndOfBuffer;
        const s = self.buf[start..self.pos];
        self.pos += 1; // consume null
        return s;
    }
};

pub fn deserializeK(allocator: std.mem.Allocator, r: *Reader) !K {
    const type_byte = try r.readI8();
    const _attr = try r.readU8();
    _ = _attr;

    switch (type_byte) {
        -1 => return K{ .boolean = (try r.readU8()) != 0 },
        -4 => return K{ .byte = try r.readU8() },
        -5 => {
            if (r.pos + 2 > r.buf.len) return error.EndOfBuffer;
            const v = std.mem.readInt(i16, r.buf[r.pos..][0..2], .little);
            r.pos += 2;
            return K{ .short = v };
        },
        -6 => return K{ .int = try r.readI32() },
        -7 => return K{ .long = try r.readI64() },
        -8 => return K{ .real = try r.readF32() },
        -9 => return K{ .float = try r.readF64() },
        -10 => return K{ .char = try r.readU8() },
        -11 => { const s = try r.readSym(); _ = s; return K{ .symbol = 0 }; }, // intern separately
        -12 => return K{ .timestamp = try r.readI64() },
        -14 => return K{ .date = try r.readI32() },
        -16 => return K{ .time = try r.readI32() },
        1 => { // KB
            const n = try r.readU32();
            const out = try allocator.alloc(bool, n);
            for (out) |*x| x.* = (try r.readU8()) != 0;
            return K{ .KB = .{ .items = out } };
        },
        4 => { // KG
            const n = try r.readU32();
            const out = try allocator.alloc(u8, n);
            if (r.pos + n > r.buf.len) return error.EndOfBuffer;
            @memcpy(out, r.buf[r.pos..][0..n]);
            r.pos += n;
            return K{ .KG = .{ .items = out } };
        },
        6 => { // KI
            const n = try r.readU32();
            const out = try allocator.alloc(i32, n);
            for (out) |*x| x.* = try r.readI32();
            return K{ .KI = .{ .items = out } };
        },
        7 => { // KJ
            const n = try r.readU32();
            const out = try allocator.alloc(i64, n);
            for (out) |*x| x.* = try r.readI64();
            return K{ .KJ = .{ .items = out } };
        },
        8 => { // KE
            const n = try r.readU32();
            const out = try allocator.alloc(f32, n);
            for (out) |*x| x.* = try r.readF32();
            return K{ .KE = .{ .items = out } };
        },
        9 => { // KF
            const n = try r.readU32();
            const out = try allocator.alloc(f64, n);
            for (out) |*x| x.* = try r.readF64();
            return K{ .KF = .{ .items = out } };
        },
        10 => { // KC (string)
            const n = try r.readU32();
            const out = try allocator.alloc(u8, n);
            if (r.pos + n > r.buf.len) return error.EndOfBuffer;
            @memcpy(out, r.buf[r.pos..][0..n]);
            r.pos += n;
            return K{ .KC = .{ .items = out } };
        },
        12 => { // KP
            const n = try r.readU32();
            const out = try allocator.alloc(i64, n);
            for (out) |*x| x.* = try r.readI64();
            return K{ .KP = .{ .items = out } };
        },
        14 => { // KD
            const n = try r.readU32();
            const out = try allocator.alloc(i32, n);
            for (out) |*x| x.* = try r.readI32();
            return K{ .KD = .{ .items = out } };
        },
        16 => { // KT
            const n = try r.readU32();
            const out = try allocator.alloc(i32, n);
            for (out) |*x| x.* = try r.readI32();
            return K{ .KT = .{ .items = out } };
        },
        else => return error.UnknownType,
    }
}

test "serialize and deserialize KJ vector" {
    const allocator = std.testing.allocator;
    var items = [_]i64{ 1, 2, 3, 100, -5 };
    const k = K{ .KJ = .{ .items = &items } };

    var w = Writer.init(allocator);
    defer w.deinit();
    try serializeK(&w, k, null);

    var r = Reader{ .buf = w.items };
    const out = try deserializeK(allocator, &r);
    defer allocator.free(out.KJ.items);

    try std.testing.expectEqualSlices(i64, &items, out.KJ.items);
}

test "serialize KF vector round-trip" {
    const allocator = std.testing.allocator;
    var items = [_]f64{ 1.5, 2.5, 3.14159 };
    const k = K{ .KF = .{ .items = &items } };

    var w = Writer.init(allocator);
    defer w.deinit();
    try serializeK(&w, k, null);

    var r = Reader{ .buf = w.items };
    const out = try deserializeK(allocator, &r);
    defer allocator.free(out.KF.items);

    for (items, 0..) |x, i| {
        try std.testing.expectApproxEqAbs(x, out.KF.items[i], 1e-10);
    }
}

test "frame message header" {
    const allocator = std.testing.allocator;
    const body = [_]u8{ 0xFF, 0x01, 0x02 };
    const msg = try frameMessage(allocator, &body, .response);
    defer allocator.free(msg);

    try std.testing.expectEqual(@as(u8, 1), msg[0]); // little-endian
    try std.testing.expectEqual(@as(u8, 2), msg[1]); // response
    const total = std.mem.readInt(u32, msg[4..8], .little);
    try std.testing.expectEqual(@as(u32, 11), total); // 8 header + 3 body
}
