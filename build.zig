const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zkdb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zkdb",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/persist_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("zkdb", mod);
    const demo = b.addExecutable(.{ .name = "zkdb-column-task", .root_module = demo_mod });
    b.installArtifact(demo);
    const demo_step = b.step("demo", "Write, close, reopen and query a small column");
    demo_step.dependOn(&b.addRunArtifact(demo).step);

    // Benchmark exe
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("zkdb", mod);
    const bench = b.addExecutable(.{
        .name = "zkdb-bench",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // REPL exe
    const repl_mod = b.createModule(.{
        .root_source_file = b.path("src/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_mod.addImport("zkdb", mod);
    const repl = b.addExecutable(.{
        .name = "zkdb-repl",
        .root_module = repl_mod,
    });
    b.installArtifact(repl);
    const repl_step = b.step("repl", "Run the q REPL");
    repl_step.dependOn(&b.addRunArtifact(repl).step);
}
