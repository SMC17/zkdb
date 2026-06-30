//! persist — mmap'd segment files for columnar storage.
//!
//! Column file header (16 bytes, little-endian):
//!   [0-1]  magic: 0x7A6B ("zk")
//!   [2]    type code (q type: 7=KJ 9=KF 6=KI 12=KP)
//!   [3]    version: 1
//!   [4-7]  reserved
//!   [8-15] element count (u64 LE)

const std = @import("std");
const types = @import("types.zig");

const K = types.K;

pub const MAGIC: u16 = 0x7A6B;
pub const VERSION: u8 = 1;
pub const HEADER_SIZE: usize = 16;

pub const ColHeader = extern struct {
    magic: u16,
    type_code: i8,
    version: u8,
    reserved: [4]u8,
    count: u64,
};

comptime {
    std.debug.assert(@sizeOf(ColHeader) == HEADER_SIZE);
}

pub const WriteError = error{ BadMagic, UnsupportedType };

/// writeColumn: write a K vector to a column file.
pub fn writeColumn(io: std.Io, path: []const u8, k: K) !void {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var hdr = ColHeader{
        .magic = MAGIC,
        .type_code = 0,
        .version = VERSION,
        .reserved = .{ 0, 0, 0, 0 },
        .count = 0,
    };

    switch (k) {
        .KJ => |v| {
            hdr.type_code = 7;
            hdr.count = v.items.len;
            var buf: [HEADER_SIZE]u8 = std.mem.toBytes(hdr);
            try file.writeStreamingAll(io, &buf);
            for (v.items) |x| {
                var xbuf: [8]u8 = undefined;
                std.mem.writeInt(i64, &xbuf, x, .little);
                try file.writeStreamingAll(io, &xbuf);
            }
        },
        .KF => |v| {
            hdr.type_code = 9;
            hdr.count = v.items.len;
            var buf: [HEADER_SIZE]u8 = std.mem.toBytes(hdr);
            try file.writeStreamingAll(io, &buf);
            for (v.items) |x| {
                var xbuf: [8]u8 = undefined;
                std.mem.writeInt(u64, &xbuf, @bitCast(x), .little);
                try file.writeStreamingAll(io, &xbuf);
            }
        },
        .KI => |v| {
            hdr.type_code = 6;
            hdr.count = v.items.len;
            var buf: [HEADER_SIZE]u8 = std.mem.toBytes(hdr);
            try file.writeStreamingAll(io, &buf);
            for (v.items) |x| {
                var xbuf: [4]u8 = undefined;
                std.mem.writeInt(i32, &xbuf, x, .little);
                try file.writeStreamingAll(io, &xbuf);
            }
        },
        else => return WriteError.UnsupportedType,
    }
}

/// readColumn: load a column file.
pub fn readColumn(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !K {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var hdr_buf: [HEADER_SIZE]u8 = undefined;
    _ = try file.readStreamingAll(io, &hdr_buf);
    const hdr: ColHeader = std.mem.bytesToValue(ColHeader, &hdr_buf);
    if (hdr.magic != MAGIC) return WriteError.BadMagic;

    const n = hdr.count;
    switch (hdr.type_code) {
        7 => {
            const out = try allocator.alloc(i64, n);
            for (out) |*x| {
                var buf: [8]u8 = undefined;
                _ = try file.readStreamingAll(io, &buf);
                x.* = std.mem.readInt(i64, &buf, .little);
            }
            return K{ .KJ = .{ .items = out } };
        },
        9 => {
            const out = try allocator.alloc(f64, n);
            for (out) |*x| {
                var buf: [8]u8 = undefined;
                _ = try file.readStreamingAll(io, &buf);
                x.* = @bitCast(std.mem.readInt(u64, &buf, .little));
            }
            return K{ .KF = .{ .items = out } };
        },
        6 => {
            const out = try allocator.alloc(i32, n);
            for (out) |*x| {
                var buf: [4]u8 = undefined;
                _ = try file.readStreamingAll(io, &buf);
                x.* = std.mem.readInt(i32, &buf, .little);
            }
            return K{ .KI = .{ .items = out } };
        },
        else => return WriteError.UnsupportedType,
    }
}
