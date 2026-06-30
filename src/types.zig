//! types — q/K type system in Zig.
//!
//! q has 20 primitive types (positive codes = vectors, negative = atoms)
//! plus dictionary (99) and table (98). We map them to Zig types directly.
//!
//! Timestamp epoch: 2000-01-01T00:00:00 UTC (not Unix).
//! Null sentinel: minInt for integers, NaN for floats.

const std = @import("std");

pub const KTypeTag = enum(i8) {
    // atoms (negative)
    boolean = -1,
    byte = -4,
    short = -5,
    int = -6,
    long = -7,
    real = -8,
    float = -9,
    char = -10,
    symbol = -11,
    timestamp = -12,
    date = -14,
    time = -16,
    // vectors (positive)
    KB = 1,
    KG = 4,
    KH = 5,
    KI = 6,
    KJ = 7,
    KE = 8,
    KF = 9,
    KC = 10,
    KS = 11,
    KP = 12,
    KD = 14,
    KT = 16,
    // compound
    list = 0,
    dict = 99,
    table = 98,
};

pub const Attr = enum(u8) { none = 0, sorted = 1, unique = 2, parted = 3, grouped = 7 };

pub const K = union(KTypeTag) {
    // atoms
    boolean: bool,
    byte: u8,
    short: i16,
    int: i32,
    long: i64,
    real: f32,
    float: f64,
    char: u8,
    symbol: u32,   // index into SymTable
    timestamp: i64, // ns since 2000-01-01
    date: i32,     // days since 2000-01-01
    time: i32,     // ms since midnight
    // vectors
    KB: KVec(bool),
    KG: KVec(u8),
    KH: KVec(i16),
    KI: KVec(i32),
    KJ: KVec(i64),
    KE: KVec(f32),
    KF: KVec(f64),
    KC: KVec(u8),  // char vector = string
    KS: KVec(u32), // symbol vector
    KP: KVec(i64), // timestamp vector
    KD: KVec(i32), // date vector
    KT: KVec(i32), // time vector
    // compound
    list: []K,
    dict: *Dict,
    table: *Table,
};

pub fn KVec(comptime T: type) type {
    return struct {
        items: []T,
        attr: Attr = .none,

        pub fn len(self: @This()) usize {
            return self.items.len;
        }
    };
}

pub const Dict = struct {
    keys: *K,
    values: *K,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    columns: std.StringHashMap(K),
    // row count derived from first column

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .allocator = allocator,
            .columns = std.StringHashMap(K).init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        self.columns.deinit();
    }

    pub fn rowCount(self: *const Table) usize {
        var it = self.columns.iterator();
        if (it.next()) |entry| return kVecLen(entry.value_ptr.*);
        return 0;
    }

    pub fn colCount(self: *const Table) usize {
        return self.columns.count();
    }
};

pub fn kVecLen(k: K) usize {
    return switch (k) {
        .KB => |v| v.items.len,
        .KG => |v| v.items.len,
        .KH => |v| v.items.len,
        .KI => |v| v.items.len,
        .KJ => |v| v.items.len,
        .KE => |v| v.items.len,
        .KF => |v| v.items.len,
        .KC => |v| v.items.len,
        .KS => |v| v.items.len,
        .KP => |v| v.items.len,
        .KD => |v| v.items.len,
        .KT => |v| v.items.len,
        .list => |l| l.len,
        else => 0,
    };
}

// Null sentinels (q-compatible)
pub const NULL = struct {
    pub const short: i16 = std.math.minInt(i16);
    pub const int: i32 = std.math.minInt(i32);
    pub const long: i64 = std.math.minInt(i64);
    pub const real: f32 = std.math.nan(f32);
    pub const float: f64 = std.math.nan(f64);
    pub const timestamp: i64 = std.math.minInt(i64);
    pub const date: i32 = std.math.minInt(i32);
    pub const time: i32 = std.math.minInt(i32);
};

pub const INF = struct {
    pub const short: i16 = std.math.maxInt(i16);
    pub const int: i32 = std.math.maxInt(i32);
    pub const long: i64 = std.math.maxInt(i64);
    pub const real: f32 = std.math.inf(f32);
    pub const float: f64 = std.math.inf(f64);
};

// q epoch: 2000-01-01 = Unix timestamp 946684800
pub const Q_EPOCH_NS: i64 = 946684800 * std.time.ns_per_s;

pub fn unixNsToKp(unix_ns: i64) i64 {
    return unix_ns - Q_EPOCH_NS;
}

pub fn kpToUnixNs(kp: i64) i64 {
    return kp + Q_EPOCH_NS;
}
