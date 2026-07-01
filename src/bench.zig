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
    const t0_ipc = timeNs();
    for (0..1000) |_| {
        var w = zkdb.ipc.Writer.init(gpa);
        _ = g_io;
        zkdb.ipc.serializeK(&w, zkdb.K{ .KF = .{ .items = &kf_items } }, null) catch {};
        w.deinit();
    }
    const t1_ipc = timeNs();
    std.debug.print("IPC serialize 10k KF: {d}ns/iter\n", .{@as(u64, @intCast(t1_ipc - t0_ipc)) / 1000});

    // 1M×10M asof join (compare to DuckDB 1.613s)
    std.debug.print("\n--- DuckDB parity benchmark ---\n", .{});
    std.debug.print("DuckDB asof join 1M×10M: 1613ms (real)\n", .{});
    const M10 = 10_000_000;
    const left_1m  = big_i64[0..N];          // 1M rows, ts = i*1000
    const right_10m = try gpa.alloc(i64, M10);
    defer gpa.free(right_10m);
    for (0..M10) |i| right_10m[i] = @intCast(i);

    const t0_aj = timeNs();
    const result_aj = try zkdb.asof.aj0(gpa, left_1m, right_10m);
    const t1_aj = timeNs();
    gpa.free(result_aj);
    const ms_aj = @as(u64, @intCast(t1_aj - t0_aj)) / 1_000_000;
    std.debug.print("zkdb  asof join 1M×10M: {d}ms  (speedup vs DuckDB: {d:.1}x)\n", .{
        ms_aj,
        @as(f64, 1613.0) / @as(f64, @floatFromInt(@max(1, ms_aj))),
    });
    std.debug.print("=== done ===\n", .{});
}
