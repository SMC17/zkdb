//! eval — q expression evaluator.
//!
//! Walks a parse.Node tree and returns a K value.
//! The Env holds variable bindings. Built-in q verbs are resolved
//! by name from the standard library table (sum, avg, min, max, count, etc.).
//!
//! Right-to-left evaluation is already encoded in the AST (the parser
//! produces right-associative trees), so the evaluator is a simple
//! post-order walk.

const std = @import("std");
const types = @import("types.zig");
const symbol = @import("symbol.zig");
const verbs = @import("verbs.zig");
const vec = @import("vector.zig");
const parse = @import("parse.zig");

const K = types.K;
const Node = parse.Node;
const NodeTag = parse.NodeTag;

pub const EvalError = error{
    UnknownName,
    WrongArgCount,
    TypeMismatch,
    OutOfMemory,
    LengthMismatch,
    DivisionByZero,
    IndexOutOfRange,
    ColumnNotFound,
    UnsupportedType,
    UnsupportedVerb,
};

pub const Env = struct {
    vars: std.StringHashMap(K),
    sym: symbol.SymTable,
    parent: ?*const Env,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{
            .vars = std.StringHashMap(K).init(allocator),
            .sym = symbol.SymTable.init(allocator),
            .parent = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Env) void {
        var it = self.vars.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.vars.deinit();
        self.sym.deinit();
    }

    pub fn get(self: *const Env, name: []const u8) ?K {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn set(self: *Env, name: []const u8, val: K) !void {
        // Dupe the key so it survives source-buffer reuse.
        const gop = try self.vars.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = val;
    }
};

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    env: Env,

    pub fn init(allocator: std.mem.Allocator) Interpreter {
        return .{ .allocator = allocator, .env = Env.init(allocator) };
    }

    pub fn deinit(self: *Interpreter) void {
        self.env.deinit();
    }

    pub fn eval(self: *Interpreter, node: *const Node) EvalError!K {
        return self.evalNode(node, &self.env);
    }

    fn evalNode(self: *Interpreter, node: *const Node, env: *Env) EvalError!K {
        return switch (node.*) {
            .atom => |k| k,

            .vector_i => |items| {
                const out = try self.allocator.alloc(i64, items.len);
                @memcpy(out, items);
                return K{ .KJ = .{ .items = out } };
            },

            .vector_f => |items| {
                const out = try self.allocator.alloc(f64, items.len);
                @memcpy(out, items);
                return K{ .KF = .{ .items = out } };
            },

            .sym_atom => |name| {
                const id = try env.sym.intern(name);
                return K{ .symbol = id };
            },

            .sym_vec => |names| {
                const out = try self.allocator.alloc(u32, names.len);
                for (names, 0..) |n, i| {
                    out[i] = try env.sym.intern(n);
                }
                return K{ .KS = .{ .items = out } };
            },

            .name => |name| {
                return env.get(name) orelse return EvalError.UnknownName;
            },

            .assign => |a| {
                const val = try self.evalNode(a.rhs, env);
                try env.set(a.name, val);
                return val;
            },

            .monadic => |m| {
                const operand = try self.evalNode(m.operand, env);
                return self.evalMonadic(m.verb, operand);
            },

            .dyadic => |d| {
                const lhs = try self.evalNode(d.lhs, env);
                const rhs = try self.evalNode(d.rhs, env);
                return self.evalDyadic(d.verb, lhs, rhs);
            },

            .call => |c| {
                // Evaluate args first (don't eval func node — builtins aren't in env).
                var arg_vals = try self.allocator.alloc(K, c.args.len);
                defer self.allocator.free(arg_vals);
                for (c.args, 0..) |a, i| {
                    arg_vals[i] = try self.evalNode(a, env);
                }
                // Named dispatch: builtins take priority, then env lookup.
                if (c.func.* == .name) {
                    const name = c.func.name;
                    if (arg_vals.len == 1) {
                        const r = self.dispatchNamedMonadic(name, arg_vals[0]);
                        if (r != EvalError.UnknownName) return r;
                    }
                    if (env.get(name)) |_| {
                        // Future: call lambda with args
                        return EvalError.UnsupportedVerb;
                    }
                    return EvalError.UnknownName;
                }
                return EvalError.UnsupportedVerb;
            },

            .lambda => {
                // Return lambda as a K list for now (closures not yet stored in K)
                return K{ .long = 0 };
            },

            .seq => |nodes| {
                var last: K = K{ .long = 0 };
                for (nodes) |n| {
                    last = try self.evalNode(n, env);
                }
                return last;
            },

            .select_q => EvalError.UnsupportedVerb,
        };
    }

    fn evalMonadic(self: *Interpreter, verb: u8, operand: K) EvalError!K {
        return switch (verb) {
            '+' => switch (operand) {  // flip
                .long => |v| K{ .long = v },
                .float => |v| K{ .float = v },
                else => EvalError.UnsupportedVerb,
            },
            '-' => switch (operand) {  // negate
                .long => |v| K{ .long = -v },
                .float => |v| K{ .float = -v },
                .KJ => |v| blk: {
                    const out = try self.allocator.alloc(i64, v.items.len);
                    for (v.items, 0..) |x, i| out[i] = -x;
                    break :blk K{ .KJ = .{ .items = out } };
                },
                .KF => |v| blk: {
                    const out = try self.allocator.alloc(f64, v.items.len);
                    for (v.items, 0..) |x, i| out[i] = -x;
                    break :blk K{ .KF = .{ .items = out } };
                },
                else => EvalError.TypeMismatch,
            },
            '#' => K{ .long = @intCast(types.kVecLen(operand)) },  // count
            '*' => switch (operand) {  // first
                .KJ => |v| if (v.items.len > 0) K{ .long = v.items[0] } else K{ .long = 0 },
                .KF => |v| if (v.items.len > 0) K{ .float = v.items[0] } else K{ .float = 0.0 },
                else => EvalError.UnsupportedVerb,
            },
            '&' => verbs.kMin(operand) catch return EvalError.TypeMismatch,  // min
            '|' => verbs.kMax(operand) catch return EvalError.TypeMismatch,  // max
            else => EvalError.UnsupportedVerb,
        };
    }

    fn evalDyadic(self: *Interpreter, verb: u8, lhs: K, rhs: K) EvalError!K {
        return switch (verb) {
            '+' => switch (lhs) {
                .long => |a| switch (rhs) {
                    .long  => |b| K{ .long  = a + b },
                    .float => |b| K{ .float = @as(f64, @floatFromInt(a)) + b },
                    else => EvalError.TypeMismatch,
                },
                .float => |a| switch (rhs) {
                    .float => |b| K{ .float = a + b },
                    .long  => |b| K{ .float = a + @as(f64, @floatFromInt(b)) },
                    else => EvalError.TypeMismatch,
                },
                else => verbs.kAdd(self.allocator, lhs, rhs) catch |e| return switch (e) {
                    error.TypeMismatch => EvalError.TypeMismatch,
                    error.LengthMismatch => EvalError.LengthMismatch,
                    else => EvalError.TypeMismatch,
                },
            },
            '-' => switch (lhs) {
                .long => |a| switch (rhs) {
                    .long  => |b| K{ .long  = a - b },
                    .float => |b| K{ .float = @as(f64, @floatFromInt(a)) - b },
                    else => EvalError.TypeMismatch,
                },
                .float => |a| switch (rhs) {
                    .float => |b| K{ .float = a - b },
                    .long  => |b| K{ .float = a - @as(f64, @floatFromInt(b)) },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            '*' => switch (lhs) {
                .long  => |a| switch (rhs) {
                    .long  => |b| K{ .long  = a * b },
                    .float => |b| K{ .float = @as(f64, @floatFromInt(a)) * b },
                    else => EvalError.TypeMismatch,
                },
                .float => |a| switch (rhs) {
                    .float => |b| K{ .float = a * b },
                    .long  => |b| K{ .float = a * @as(f64, @floatFromInt(b)) },
                    else => EvalError.TypeMismatch,
                },
                else => verbs.kMul(self.allocator, lhs, rhs) catch return EvalError.TypeMismatch,
            },
            '%' => switch (lhs) {
                .long => |a| switch (rhs) {
                    .long => |b| if (b == 0) EvalError.DivisionByZero else K{ .float = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b)) },
                    else => EvalError.TypeMismatch,
                },
                .float => |a| switch (rhs) {
                    .float => |b| K{ .float = a / b },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            '&' => switch (lhs) {  // min (dyadic)
                .long => |a| switch (rhs) {
                    .long => |b| K{ .long = @min(a, b) },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            '|' => switch (lhs) {  // max (dyadic)
                .long => |a| switch (rhs) {
                    .long => |b| K{ .long = @max(a, b) },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            '=' => switch (lhs) {
                .long => |a| switch (rhs) {
                    .long => |b| K{ .boolean = a == b },
                    else => EvalError.TypeMismatch,
                },
                .float => |a| switch (rhs) {
                    .float => |b| K{ .boolean = a == b },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            '<' => switch (lhs) {
                .long => |a| switch (rhs) { .long => |b| K{ .boolean = a < b }, else => EvalError.TypeMismatch },
                .float => |a| switch (rhs) { .float => |b| K{ .boolean = a < b }, else => EvalError.TypeMismatch },
                else => EvalError.UnsupportedVerb,
            },
            '>' => switch (lhs) {
                .long => |a| switch (rhs) { .long => |b| K{ .boolean = a > b }, else => EvalError.TypeMismatch },
                .float => |a| switch (rhs) { .float => |b| K{ .boolean = a > b }, else => EvalError.TypeMismatch },
                else => EvalError.UnsupportedVerb,
            },
            '#' => switch (lhs) {  // take (dyadic #)
                .long => |n| switch (rhs) {
                    .KJ => |v| blk: {
                        const count: usize = @intCast(@max(0, n));
                        const out = try self.allocator.alloc(i64, count);
                        for (0..count) |i| out[i] = v.items[i % v.items.len];
                        break :blk K{ .KJ = .{ .items = out } };
                    },
                    .KF => |v| blk: {
                        const count: usize = @intCast(@max(0, n));
                        const out = try self.allocator.alloc(f64, count);
                        for (0..count) |i| out[i] = v.items[i % v.items.len];
                        break :blk K{ .KF = .{ .items = out } };
                    },
                    else => EvalError.UnsupportedVerb,
                },
                else => EvalError.UnsupportedVerb,
            },
            ',' => switch (lhs) {  // join / cat
                .KJ => |va| switch (rhs) {
                    .KJ => |vb| blk: {
                        const out = try self.allocator.alloc(i64, va.items.len + vb.items.len);
                        @memcpy(out[0..va.items.len], va.items);
                        @memcpy(out[va.items.len..], vb.items);
                        break :blk K{ .KJ = .{ .items = out } };
                    },
                    else => EvalError.TypeMismatch,
                },
                else => EvalError.UnsupportedVerb,
            },
            else => EvalError.UnsupportedVerb,
        };
    }

    fn dispatchNamedMonadic(self: *Interpreter, name: []const u8, arg: K) EvalError!K {
        if (std.mem.eql(u8, name, "sum")) return verbs.kSum(arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "avg")) return verbs.kAvg(arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "min")) return verbs.kMin(arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "max")) return verbs.kMax(arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "count")) return verbs.kCount(arg);
        if (std.mem.eql(u8, name, "var")) return verbs.kVar(self.allocator, arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "dev")) return verbs.kDev(self.allocator, arg) catch return EvalError.TypeMismatch;
        if (std.mem.eql(u8, name, "count")) return verbs.kCount(arg);
        if (std.mem.eql(u8, name, "prd")) return verbs.kSum(arg) catch return EvalError.TypeMismatch; // TODO: proper prd
        if (std.mem.eql(u8, name, "neg")) return self.evalMonadic('-', arg);
        if (std.mem.eql(u8, name, "abs")) return switch (arg) {
            .long => |v| K{ .long = @intCast(@abs(v)) },
            .float => |v| K{ .float = @abs(v) },
            else => EvalError.TypeMismatch,
        };
        return EvalError.UnknownName;
    }
};

// ---- Printing K values in q format ----

pub fn printK(writer: anytype, k: K, sym_names: ?[]const []const u8) !void {
    switch (k) {
        .boolean => |v| try writer.print("{s}", .{if (v) "1b" else "0b"}),
        .long    => |v| try writer.print("{d}", .{v}),
        .int     => |v| try writer.print("{d}i", .{v}),
        .float   => |v| {
            if (std.math.isNan(v)) try writer.writeAll("0n")
            else if (std.math.isInf(v)) try writer.writeAll(if (v > 0) "0w" else "-0w")
            else try writer.print("{d}", .{v});
        },
        .symbol  => |id| {
            if (sym_names) |ns| {
                if (id < ns.len) try writer.print("`{s}", .{ns[id]});
            } else {
                try writer.print("`sym#{d}", .{id});
            }
        },
        .KJ => |v| {
            for (v.items, 0..) |x, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{x});
            }
        },
        .KF => |v| {
            for (v.items, 0..) |x, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{x});
            }
        },
        .KS => |v| {
            for (v.items, 0..) |id, i| {
                if (i > 0) try writer.writeByte(' ');
                if (sym_names) |ns| {
                    if (id < ns.len) {
                        try writer.print("`{s}", .{ns[id]});
                    } else {
                        try writer.print("`?", .{});
                    }
                } else {
                    try writer.print("`{d}", .{id});
                }
            }
        },
        .KB => |v| {
            for (v.items) |b| try writer.writeByte(if (b) '1' else '0');
            try writer.writeByte('b');
        },
        else => try writer.print("<{s}>", .{@tagName(k)}),
    }
}

test "eval 2 + 3 * 4 = 14" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lex = @import("lex.zig");
    const toks = try lex.Lexer.tokenize(alloc, "2 + 3 * 4");
    var p = parse.Parser.init(alloc, toks);
    defer p.deinit();
    const node = try p.parseExpr();

    var interp = Interpreter.init(alloc);
    defer interp.deinit();
    const result = try interp.eval(node);
    try std.testing.expectEqual(@as(i64, 14), result.long);
}

test "eval sum vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lex = @import("lex.zig");
    const toks = try lex.Lexer.tokenize(alloc, "sum 1 2 3 4 5");
    var p = parse.Parser.init(alloc, toks);
    defer p.deinit();
    const node = try p.parseExpr();

    var interp = Interpreter.init(alloc);
    defer interp.deinit();
    const result = try interp.eval(node);
    try std.testing.expectEqual(@as(i64, 15), result.long);
}

test "eval assign and recall" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const lex = @import("lex.zig");

    var interp = Interpreter.init(alloc);
    defer interp.deinit();

    const toks1 = try lex.Lexer.tokenize(alloc, "x: 10");
    var p1 = parse.Parser.init(alloc, toks1);
    defer p1.deinit();
    _ = try interp.eval(try p1.parseExpr());

    const toks2 = try lex.Lexer.tokenize(alloc, "x + 5");
    var p2 = parse.Parser.init(alloc, toks2);
    defer p2.deinit();
    const result = try interp.eval(try p2.parseExpr());
    try std.testing.expectEqual(@as(i64, 15), result.long);
}

test "eval count takes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const lex = @import("lex.zig");

    var interp = Interpreter.init(alloc);
    defer interp.deinit();

    // # 1 2 3 = 3
    const toks = try lex.Lexer.tokenize(alloc, "# 1 2 3");
    var p = parse.Parser.init(alloc, toks);
    defer p.deinit();
    const result = try interp.eval(try p.parseExpr());
    try std.testing.expectEqual(@as(i64, 3), result.long);
}

test "eval avg float vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const lex = @import("lex.zig");

    var interp = Interpreter.init(alloc);
    defer interp.deinit();

    const toks = try lex.Lexer.tokenize(alloc, "avg 1.0 2.0 3.0");
    var p = parse.Parser.init(alloc, toks);
    defer p.deinit();
    const result = try interp.eval(try p.parseExpr());
    try std.testing.expectApproxEqAbs(2.0, result.float, 1e-9);
}
