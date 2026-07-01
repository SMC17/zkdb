//! repl — minimal q/zkdb interactive REPL.
//!
//! Zig 0.16: std.io is gone. Uses raw Linux fd syscalls + std.fmt.bufPrint.

const std = @import("std");
const linux = std.os.linux;
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const eval = @import("eval.zig");

/// Minimal writer wrapping a Linux fd; compatible with std.fmt writer protocol.
const FdWriter = struct {
    fd: i32,

    pub const Error = error{};

    pub fn writeAll(self: FdWriter, bytes: []const u8) Error!void {
        _ = linux.write(self.fd, bytes.ptr, bytes.len);
    }

    pub fn writeByte(self: FdWriter, b: u8) Error!void {
        try self.writeAll(&.{b});
    }

    pub fn print(self: FdWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        try self.writeAll(s);
    }

    pub fn write(self: FdWriter, bytes: []const u8) Error!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
};

const out = FdWriter{ .fd = 1 };

fn readLine(buf: []u8) ?[]u8 {
    var i: usize = 0;
    var ch: [1]u8 = undefined;
    while (i < buf.len) {
        const r = linux.read(0, &ch, 1);
        if (r <= 0) return if (i > 0) buf[0..i] else null;
        if (ch[0] == '\r') continue;
        if (ch[0] == '\n') break;
        buf[i] = ch[0];
        i += 1;
    }
    return buf[0..i];
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa_state.allocator();

    var interp = eval.Interpreter.init(allocator);
    defer interp.deinit();

    try out.writeAll("zkdb q/z 0.1.0  (type \\\\ to quit)\n");

    var line_buf: [4096]u8 = undefined;

    while (true) {
        try out.writeAll("q) ");
        const line = readLine(&line_buf) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "\\\\")) break;

        if (std.mem.eql(u8, trimmed, "\\v")) {
            var it = interp.env.vars.iterator();
            while (it.next()) |e| {
                try out.writeAll(e.key_ptr.*);
                try out.writeAll(": ");
                try eval.printK(out, e.value_ptr.*, interp.env.sym.by_id.items);
                try out.writeAll("\n");
            }
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const toks = lex.Lexer.tokenize(arena.allocator(), trimmed) catch |e| {
            try out.print("lex error: {}\n", .{e});
            continue;
        };

        var p = parse.Parser.init(arena.allocator(), toks);
        const node = p.parseExpr() catch |e| {
            try out.print("parse error: {}\n", .{e});
            continue;
        };

        const result = interp.eval(node) catch |e| {
            try out.print("eval error: {}\n", .{e});
            continue;
        };

        try eval.printK(out, result, interp.env.sym.by_id.items);
        try out.writeAll("\n");
    }

    try out.writeAll("bye\n");
}
