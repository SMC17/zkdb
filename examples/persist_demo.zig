const std = @import("std");
const zkdb = @import("zkdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/fixture");
    const path = "zig-out/fixture/ticks.kj";
    var input = [_]i64{ 2, 3, 5, 7 };
    // writeColumn closes its descriptor before readColumn reopens the path.
    try zkdb.persist.writeColumn(io, path, .{ .KJ = .{ .items = &input } });
    const out = try zkdb.persist.readColumn(io, init.gpa, path);
    defer init.gpa.free(out.KJ.items);
    if (!std.mem.eql(i64, &input, out.KJ.items)) return error.RoundtripMismatch;
    const sum = zkdb.vector.sum(i64, out.KJ.items);
    if (sum != 17) return error.QueryMismatch;
    std.debug.print("COLUMN_TASK_OK rows={d} sum={d} write_close_reopen=true\n", .{ out.KJ.items.len, sum });
}
