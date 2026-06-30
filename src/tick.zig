//! tick — real-time tick feed subscriber with ring buffer.
//!
//! kdb+'s tick architecture: tickerplant (publisher) → subscribers (rdb, hdb).
//! We implement the subscriber side: a fixed-capacity ring buffer of K rows.
//!
//! Thread-safety: single-producer/single-consumer safe. For multi-threaded
//! publish/snapshot, caller must hold an external lock (std.Io.Mutex with io).

const std = @import("std");

pub const TickRow = struct {
    sym: u32,
    ts: i64,
    data: []f64,
};

pub fn TickFeed(comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap]TickRow,
        head: usize,
        count: usize,

        pub fn init() Self {
            return .{ .buf = undefined, .head = 0, .count = 0 };
        }

        pub fn publish(self: *Self, row: TickRow) void {
            const idx = (self.head + self.count) % cap;
            self.buf[idx] = row;
            if (self.count < cap) {
                self.count += 1;
            } else {
                self.head = (self.head + 1) % cap;
            }
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn snapshot(self: *const Self, out: []TickRow) usize {
            const n = @min(self.count, out.len);
            for (0..n) |i| {
                out[i] = self.buf[(self.head + i) % cap];
            }
            return n;
        }

        pub fn latest(self: *const Self, sym: u32) ?TickRow {
            var i: usize = self.count;
            while (i > 0) {
                i -= 1;
                const row = self.buf[(self.head + i) % cap];
                if (row.sym == sym) return row;
            }
            return null;
        }
    };
}

test "tick feed publish and snapshot" {
    var feed = TickFeed(8).init();
    const dummy_data = [_]f64{ 100.0, 200.0 };

    feed.publish(.{ .sym = 0, .ts = 1000, .data = @constCast(&dummy_data) });
    feed.publish(.{ .sym = 1, .ts = 2000, .data = @constCast(&dummy_data) });
    feed.publish(.{ .sym = 0, .ts = 3000, .data = @constCast(&dummy_data) });

    try std.testing.expectEqual(@as(usize, 3), feed.len());

    var snap: [8]TickRow = undefined;
    const n = feed.snapshot(&snap);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(i64, 1000), snap[0].ts);
    try std.testing.expectEqual(@as(i64, 3000), snap[2].ts);
}

test "tick feed latest by sym" {
    var feed = TickFeed(16).init();
    const dummy_data = [_]f64{ 42.0 };

    feed.publish(.{ .sym = 0, .ts = 100, .data = @constCast(&dummy_data) });
    feed.publish(.{ .sym = 1, .ts = 200, .data = @constCast(&dummy_data) });
    feed.publish(.{ .sym = 0, .ts = 300, .data = @constCast(&dummy_data) });

    const r = feed.latest(0) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 300), r.ts);
    try std.testing.expect(feed.latest(99) == null);
}

test "tick feed ring overflow" {
    var feed = TickFeed(3).init();
    const dummy_data = [_]f64{ 1.0 };

    for (0..6) |i| {
        feed.publish(.{ .sym = @intCast(i), .ts = @intCast(i * 100), .data = @constCast(&dummy_data) });
    }

    try std.testing.expectEqual(@as(usize, 3), feed.len());
    var snap: [3]TickRow = undefined;
    const n = feed.snapshot(&snap);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(i64, 300), snap[0].ts);
    try std.testing.expectEqual(@as(i64, 500), snap[2].ts);
}
