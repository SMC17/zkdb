//! persist — column files loaded into allocated memory.
//!
//! Writes are atomic per file: the column is written to a temporary file in
//! the same directory, fsynced, then renamed over the target, so a crash
//! leaves either the previous column or the new one, never a torn mix.
//! Version 2 files carry a CRC32 of the payload, checked on every read.
//! Not implemented: fsync of the containing directory after the rename
//! (power loss right after a write can lose that write, but not corrupt the
//! file), mmap, a WAL, and concurrent writers to the same path.
//!
//! Column file header (16 bytes, little-endian):
//!   [0-1]  magic: 0x7A6B ("zk")
//!   [2]    type code (q type: 7=KJ 9=KF 6=KI 12=KP)
//!   [3]    version: 2 (version 1 files are still read)
//!   [4-7]  CRC32 (IEEE) of the payload; zero in version 1
//!   [8-15] element count (u64 LE)

const std = @import("std");
const types = @import("types.zig");

const K = types.K;

pub const MAGIC: u16 = 0x7A6B;
pub const VERSION: u8 = 2;
/// Oldest version readColumn accepts. Version 1 has no checksum.
pub const MIN_VERSION: u8 = 1;
pub const TMP_SUFFIX = ".zkdb-tmp";
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

pub const WriteError = error{ BadMagic, UnsupportedType, UnsupportedVersion, InvalidSize, UnexpectedEof, ChecksumMismatch, PathTooLong };

fn readExact(file: std.Io.File, io: std.Io, buf: []u8, offset: u64) !void {
    const n = try file.readPositionalAll(io, buf, offset);
    if (n != buf.len) return WriteError.UnexpectedEof;
}

fn payloadCrc(k: K) u32 {
    var crc = std.hash.Crc32.init();
    switch (k) {
        .KJ => |v| for (v.items) |x| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, x, .little);
            crc.update(&b);
        },
        .KF => |v| for (v.items) |x| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(x), .little);
            crc.update(&b);
        },
        .KI => |v| for (v.items) |x| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, x, .little);
            crc.update(&b);
        },
        else => unreachable,
    }
    return crc.final();
}

/// writeColumn: atomically replace `path` with a column file holding `k`.
pub fn writeColumn(io: std.Io, path: []const u8, k: K) !void {
    // Reject unsupported input before touching the filesystem.
    const type_code: u8, const count: usize = switch (k) {
        .KJ => |v| .{ 7, v.items.len },
        .KF => |v| .{ 9, v.items.len },
        .KI => |v| .{ 6, v.items.len },
        else => return WriteError.UnsupportedType,
    };
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}{s}", .{ path, TMP_SUFFIX }) catch return WriteError.PathTooLong;

    const cwd = std.Io.Dir.cwd();
    {
        var file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        errdefer cwd.deleteFile(io, tmp_path) catch {};

        var header = [_]u8{0} ** HEADER_SIZE;
        std.mem.writeInt(u16, header[0..2], MAGIC, .little);
        header[2] = type_code;
        header[3] = VERSION;
        std.mem.writeInt(u32, header[4..8], payloadCrc(k), .little);
        std.mem.writeInt(u64, header[8..16], count, .little);
        try file.writeStreamingAll(io, &header);

        switch (k) {
            .KJ => |v| for (v.items) |x| {
                var xbuf: [8]u8 = undefined;
                std.mem.writeInt(i64, &xbuf, x, .little);
                try file.writeStreamingAll(io, &xbuf);
            },
            .KF => |v| for (v.items) |x| {
                var xbuf: [8]u8 = undefined;
                std.mem.writeInt(u64, &xbuf, @bitCast(x), .little);
                try file.writeStreamingAll(io, &xbuf);
            },
            .KI => |v| for (v.items) |x| {
                var xbuf: [4]u8 = undefined;
                std.mem.writeInt(i32, &xbuf, x, .little);
                try file.writeStreamingAll(io, &xbuf);
            },
            else => unreachable,
        }
        try file.sync(io);
    }
    std.Io.Dir.rename(cwd, tmp_path, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// readColumn: load a column file.
pub fn readColumn(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !K {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var hdr_buf: [HEADER_SIZE]u8 = undefined;
    try readExact(file, io, &hdr_buf, 0);
    if (std.mem.readInt(u16, hdr_buf[0..2], .little) != MAGIC) return WriteError.BadMagic;
    const version = hdr_buf[3];
    if (version < MIN_VERSION or version > VERSION) return WriteError.UnsupportedVersion;
    if (version == 1 and !std.mem.allEqual(u8, hdr_buf[4..8], 0)) return WriteError.UnsupportedVersion;
    const stored_crc = std.mem.readInt(u32, hdr_buf[4..8], .little);
    const type_code = hdr_buf[2];
    const count = std.mem.readInt(u64, hdr_buf[8..16], .little);
    const width: u64 = switch (type_code) {
        7, 9 => 8,
        6 => 4,
        else => return WriteError.UnsupportedType,
    };
    const payload_bytes = std.math.mul(u64, count, width) catch return WriteError.InvalidSize;
    const expected_size = std.math.add(u64, HEADER_SIZE, payload_bytes) catch return WriteError.InvalidSize;
    const actual_size = (try file.stat(io)).size;
    if (actual_size < expected_size) return WriteError.UnexpectedEof;
    if (actual_size > expected_size) return WriteError.InvalidSize;
    const n = std.math.cast(usize, count) orelse return WriteError.InvalidSize;
    var off: u64 = HEADER_SIZE;
    switch (type_code) {
        7 => {
            const out = try allocator.alloc(i64, n);
            errdefer allocator.free(out);
            for (out) |*x| {
                var buf: [8]u8 = undefined;
                try readExact(file, io, &buf, off);
                off += buf.len;
                x.* = std.mem.readInt(i64, &buf, .little);
            }
            if (version >= 2 and payloadCrc(.{ .KJ = .{ .items = out } }) != stored_crc) return WriteError.ChecksumMismatch;
            return K{ .KJ = .{ .items = out } };
        },
        9 => {
            const out = try allocator.alloc(f64, n);
            errdefer allocator.free(out);
            for (out) |*x| {
                var buf: [8]u8 = undefined;
                try readExact(file, io, &buf, off);
                off += buf.len;
                x.* = @bitCast(std.mem.readInt(u64, &buf, .little));
            }
            if (version >= 2 and payloadCrc(.{ .KF = .{ .items = out } }) != stored_crc) return WriteError.ChecksumMismatch;
            return K{ .KF = .{ .items = out } };
        },
        6 => {
            const out = try allocator.alloc(i32, n);
            errdefer allocator.free(out);
            for (out) |*x| {
                var buf: [4]u8 = undefined;
                try readExact(file, io, &buf, off);
                off += buf.len;
                x.* = std.mem.readInt(i32, &buf, .little);
            }
            if (version >= 2 and payloadCrc(.{ .KI = .{ .items = out } }) != stored_crc) return WriteError.ChecksumMismatch;
            return K{ .KI = .{ .items = out } };
        },
        else => return WriteError.UnsupportedType,
    }
}

test "writeColumn readColumn KJ round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/col.kj", .{&tmp.sub_path}) catch unreachable;

    var items = [_]i64{ -1, 0, 42, 1 << 40 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });

    const out = try readColumn(io, allocator, path);
    defer allocator.free(out.KJ.items);
    try std.testing.expectEqualSlices(i64, &items, out.KJ.items);
}

test "unsupported writes preserve an existing column" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/preserve.kj", .{&tmp.sub_path});
    var items = [_]i64{ 7, 11 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });
    try std.testing.expectError(error.UnsupportedType, writeColumn(io, path, .{ .long = 3 }));
    const out = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(out.KJ.items);
    try std.testing.expectEqualSlices(i64, &items, out.KJ.items);
}

test "unknown file version is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/version.kj", .{&tmp.sub_path});
    var items = [_]i64{1};
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &.{VERSION + 1}, 3);
    }
    if (readColumn(io, std.testing.allocator, path)) |out| {
        std.testing.allocator.free(out.KJ.items);
        return error.AcceptedUnknownVersion;
    } else |err| {
        try std.testing.expectEqual(error.UnsupportedVersion, err);
    }
}

test "declared size overflow is rejected before allocation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/huge.kj", .{&tmp.sub_path});
    var items = [_]i64{1};
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &([_]u8{0xff} ** 8), 8);
    }
    try std.testing.expectError(error.InvalidSize, readColumn(io, std.testing.allocator, path));
}

test "truncated payload is rejected before allocation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/short.kj", .{&tmp.sub_path});
    var items = [_]i64{ 1, 2 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, HEADER_SIZE + 1);
    }
    try std.testing.expectError(error.UnexpectedEof, readColumn(io, std.testing.allocator, path));
}

test "integer and floating column bytes survive close and reopen" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/typed.col", .{&tmp.sub_path});
    var integers = [_]i32{ -3, 0, 7 };
    try writeColumn(io, path, .{ .KI = .{ .items = &integers } });
    const int_out = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(int_out.KI.items);
    try std.testing.expectEqualSlices(i32, &integers, int_out.KI.items);
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var bytes: [HEADER_SIZE]u8 = undefined;
        try readExact(file, io, &bytes, 0);
        const payload = [_]u8{ 0xfd, 0xff, 0xff, 0xff, 0, 0, 0, 0, 7, 0, 0, 0 };
        var expected = [_]u8{ 0x6b, 0x7a, 6, 2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, expected[4..8], std.hash.Crc32.hash(&payload), .little);
        try std.testing.expectEqualSlices(u8, &expected, &bytes);
    }
    var floats = [_]f64{ -1.5, 0, 2.25 };
    try writeColumn(io, path, .{ .KF = .{ .items = &floats } });
    const float_out = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(float_out.KF.items);
    try std.testing.expectEqualSlices(f64, &floats, float_out.KF.items);
}

test "a flipped payload byte is caught by the checksum" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/flip.kj", .{&tmp.sub_path});
    var items = [_]i64{ 10, 20, 30 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &items } });
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &.{0x55}, HEADER_SIZE + 9);
    }
    try std.testing.expectError(error.ChecksumMismatch, readColumn(io, std.testing.allocator, path));
}

test "a write interrupted before rename leaves the previous column intact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/crash.kj", .{&tmp.sub_path});
    var tmp_buf: [160]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}{s}", .{ path, TMP_SUFFIX });

    var old = [_]i64{ 1, 2, 3 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &old } });
    // Simulate a crash mid-write: a half-written temporary file is left behind.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = "\x6b\x7a\x07\x02garbage" });

    const before = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(before.KJ.items);
    try std.testing.expectEqualSlices(i64, &old, before.KJ.items);

    // The next write replaces the leftover and lands atomically.
    var new = [_]i64{ 4, 5 };
    try writeColumn(io, path, .{ .KJ = .{ .items = &new } });
    const after = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(after.KJ.items);
    try std.testing.expectEqualSlices(i64, &new, after.KJ.items);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, tmp_path, .{}));
}

test "version 1 files without a checksum are still read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/v1.ki", .{&tmp.sub_path});
    const bytes = [_]u8{ 0x6b, 0x7a, 6, 1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0xff, 0xff, 0xff, 0xff };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &bytes });
    const out = try readColumn(io, std.testing.allocator, path);
    defer std.testing.allocator.free(out.KI.items);
    try std.testing.expectEqualSlices(i32, &.{ 9, -1 }, out.KI.items);
}
