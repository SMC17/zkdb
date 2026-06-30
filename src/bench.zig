//! bench — latency benchmarks proving the "multiple years" claim wrong.

const std = @import("std");
const zkdb = @import("zkdb");

var gpa_state: std.heap.DebugAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

const N = 1_000_000;
var big_f64: [N]f64 = undefined;
var big_i64: [N]i64 = undefined;

var sink_f64: f64 = 0;
var sink_i64: i64 = 0;

fn benchSumF64() void {
    sink_f64 = zkdb.vector.sumF(f64, &big_f64);
}

fn benchSumI64() void {
    sink_i64 = zkdb.vector.sum(i64, &big_i64);
}

fn benchAsof0() void {
    const left_ts = big_i64[0..1000];
    const right_ts = big_i64[0..10000];
    const r = zkdb.asof.aj0(gpa, left_ts, right_ts) catch return;
    gpa.free(r);
}

var g_io: std.Io = undefined;

fn timeNs() i64 {
    const ts = std.Io.Clock.Timestamp.now(g_io, .awake);
    return @intCast(ts.raw.nanoseconds);
}

fn bench(comptime name: []const u8, comptime f: fn () void, iters: usize) void {
    for (0..3) |_| f(); // warmup
    const t0 = timeNs();
    for (0..iters) |_| f();
    const t1 = timeNs();
    const elapsed_ns: u64 = @intCast(t1 - t0);
    const per_iter_ns = elapsed_ns / iters;
    std.debug.print("{s}: {d}ns/iter ({d}µs total)\n", .{
        name, per_iter_ns, elapsed_ns / 1000,
    });
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    for (0..N) |i| {
        big_f64[i] = @floatFromInt(i);
        big_i64[i] = @intCast(i * 1000);
    }

    std.debug.print("=== zkdb benchmarks ===\n", .{});
    bench("sum 1M f64", benchSumF64, 100);
    bench("sum 1M i64", benchSumI64, 100);
    bench("asof 1k×10k", benchAsof0, 1000);

    // IPC serialize 10k KF vector
    var kf_items: [10_000]f64 = undefined;
    for (0..10_000) |i| kf_items[i] = @floatFromInt(i);
    const t0 = timeNs();
    for (0..1000) |_| {
        var w = zkdb.ipc.Writer.init(gpa);
        _ = g_io;
        zkdb.ipc.serializeK(&w, zkdb.K{ .KF = .{ .items = &kf_items } }, null) catch {};
        w.deinit();
    }
    const t1 = timeNs();
    std.debug.print("IPC serialize 10k KF: {d}ns/iter\n", .{@as(u64, @intCast(t1 - t0)) / 1000});
    std.debug.print("=== done ===\n", .{});
}
