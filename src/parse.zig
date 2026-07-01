//! parse — q/k recursive-descent parser.
//!
//! Grammar (simplified, right-to-left associativity for verbs):
//!
//!   prog   ::= stmt*
//!   stmt   ::= expr nl | expr eof
//!   expr   ::= assign | dyadic | monadic | term
//!   assign ::= name ':' expr
//!   dyadic ::= term verb expr          -- right-assoc via recursion
//!   monadic::= verb expr
//!   term   ::= atom | vector | name | '(' expr ')' | lambda | term '[' args ']'
//!   vector ::= atom atom+              -- same-type atoms, space-separated
//!   args   ::= expr (';' expr)*
//!   lambda ::= '{' ('[' params ']')? expr '}'
//!   params ::= name (';' name)*

const std = @import("std");
const lex = @import("lex.zig");
const types = @import("types.zig");

const Tok = lex.Tok;
const TokKind = lex.TokKind;
const K = types.K;

pub const NodeTag = enum {
    atom,       // K literal
    vector_i,   // []i64
    vector_f,   // []f64
    sym_atom,   // single symbol literal (bare name, to be interned)
    sym_vec,    // symbol vector ([][]const u8, to be interned)
    name,       // name ref (variable lookup)
    assign,     // name ':' rhs
    dyadic,     // lhs verb rhs
    monadic,    // verb operand
    call,       // f '[' args ']'
    lambda,     // '{' ('[' params ']')? body '}'
    seq,        // exprs separated by ';' (block)
    select_q,   // select ... from ... where ...
};

pub const Node = union(NodeTag) {
    atom: K,
    vector_i: []i64,
    vector_f: []f64,
    sym_atom: []const u8,
    sym_vec: [][]const u8,
    name: []const u8,
    assign: struct { name: []const u8, rhs: *Node },
    dyadic: struct { verb: u8, lhs: *Node, rhs: *Node },
    monadic: struct { verb: u8, operand: *Node },
    call: struct { func: *Node, args: []*Node },
    lambda: struct { params: [][]const u8, body: *Node },
    seq: []*Node,
    select_q: struct {
        cols: ?[][]const u8,  // null = all
        table: []const u8,
        where: ?*Node,        // predicate node
        by: ?[]const u8,      // group-by column
    },
};

pub const ParseError = error{ UnexpectedToken, OutOfMemory, BadLiteral };

pub const Parser = struct {
    toks: []const Tok,
    pos: usize,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, toks: []const Tok) Parser {
        return .{
            .toks = toks,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn cur(self: *Parser) Tok {
        if (self.pos >= self.toks.len) return .{ .kind = .eof, .src = "", .pos = 0 };
        return self.toks[self.pos];
    }

    fn peek(self: *Parser, offset: usize) Tok {
        const i = self.pos + offset;
        if (i >= self.toks.len) return .{ .kind = .eof, .src = "", .pos = 0 };
        return self.toks[i];
    }

    fn advance(self: *Parser) Tok {
        const t = self.cur();
        self.pos += 1;
        return t;
    }

    fn skipNl(self: *Parser) void {
        while (self.cur().kind == .nl) _ = self.advance();
    }

    fn expect(self: *Parser, kind: TokKind) ParseError!Tok {
        const t = self.cur();
        if (t.kind != kind) return ParseError.UnexpectedToken;
        return self.advance();
    }

    fn newNode(self: *Parser, n: Node) ParseError!*Node {
        const p = try self.alloc().create(Node);
        p.* = n;
        return p;
    }

    // Parse a complete expression (entry point per line).
    pub fn parseExpr(self: *Parser) ParseError!*Node {
        self.skipNl();
        return self.parseE();
    }

    // e ::= assign | term (verb e)?  |  verb e
    fn parseE(self: *Parser) ParseError!*Node {
        // Monadic: verb at start of expression
        if (self.cur().kind == .verb) {
            const v = self.advance().src[0];
            const operand = try self.parseE();
            return self.newNode(.{ .monadic = .{ .verb = v, .operand = operand } });
        }

        const t = try self.parseTerm();

        // Assignment: name: expr
        if (t.* == .name and self.cur().kind == .colon) {
            _ = self.advance();
            const rhs = try self.parseE();
            return self.newNode(.{ .assign = .{ .name = t.name, .rhs = rhs } });
        }

        // Dyadic: term verb e
        if (self.cur().kind == .verb) {
            const v = self.advance().src[0];
            const rhs = try self.parseE();
            return self.newNode(.{ .dyadic = .{ .verb = v, .lhs = t, .rhs = rhs } });
        }

        return t;
    }

    fn isTermStart(kind: TokKind) bool {
        return switch (kind) {
            .int, .float, .bool_, .sym, .char, .string, .name,
            .lparen, .lbrace, .kw_select, .kw_update, .kw_delete => true,
            else => false,
        };
    }

    // term ::= atom | vector | name | '(' e ')' | '{' body '}' | select
    //        | name term            -- juxtaposition = monadic call (q idiom)
    //        | term '[' args ']'    -- left-associative indexing
    fn parseTerm(self: *Parser) ParseError!*Node {
        var base = try self.parseBase();

        // Juxtaposition: name immediately followed by a term-starting token
        // means function application: `sum 1 2 3` = sum[1 2 3]
        if (base.* == .name and isTermStart(self.cur().kind)) {
            const arg = try self.parseE();
            const args = try self.alloc().alloc(*Node, 1);
            args[0] = arg;
            base = try self.newNode(.{ .call = .{ .func = base, .args = args } });
        }

        // Left-associative: term '[' args ']'
        while (self.cur().kind == .lbracket) {
            _ = self.advance();
            var args_list = std.array_list.Managed(*Node).init(self.alloc());
            self.skipNl();
            if (self.cur().kind != .rbracket) {
                try args_list.append(try self.parseE());
                while (self.cur().kind == .semi) {
                    _ = self.advance();
                    try args_list.append(try self.parseE());
                }
            }
            _ = try self.expect(.rbracket);
            const args = try args_list.toOwnedSlice();
            base = try self.newNode(.{ .call = .{ .func = base, .args = args } });
        }
        return base;
    }

    fn parseBase(self: *Parser) ParseError!*Node {
        switch (self.cur().kind) {
            .lparen => {
                _ = self.advance();
                self.skipNl();
                var exprs = std.array_list.Managed(*Node).init(self.alloc());
                try exprs.append(try self.parseE());
                while (self.cur().kind == .semi) {
                    _ = self.advance();
                    try exprs.append(try self.parseE());
                }
                _ = try self.expect(.rparen);
                const items = try exprs.toOwnedSlice();
                if (items.len == 1) return items[0];
                return self.newNode(.{ .seq = items });
            },
            .lbrace => return self.parseLambda(),
            .kw_select, .kw_update, .kw_delete => return self.parseSelect(),
            .int => return self.parseAtomOrVector(),
            .float => return self.parseAtomOrVector(),
            .bool_ => return self.parseAtomOrVector(),
            .sym => return self.parseAtomOrVector(),
            .string, .char => {
                const t = self.advance();
                return self.newNode(.{ .atom = K{ .KC = .{ .items = @constCast(t.src) } } });
            },
            .name => {
                const t = self.advance();
                return self.newNode(.{ .name = t.src });
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    // Parse int/float/bool/sym — with vector lookahead for same-type runs.
    fn parseAtomOrVector(self: *Parser) ParseError!*Node {
        const first = self.cur();
        switch (first.kind) {
            .int => {
                var vals = std.array_list.Managed(i64).init(self.alloc());
                while (self.cur().kind == .int) {
                    try vals.append(try parseInt(self.advance().src));
                }
                const items = try vals.toOwnedSlice();
                if (items.len == 1) return self.newNode(.{ .atom = K{ .long = items[0] } });
                return self.newNode(.{ .vector_i = items });
            },
            .float => {
                var vals = std.array_list.Managed(f64).init(self.alloc());
                while (self.cur().kind == .float) {
                    try vals.append(try parseFloat(self.advance().src));
                }
                const items = try vals.toOwnedSlice();
                if (items.len == 1) return self.newNode(.{ .atom = K{ .float = items[0] } });
                return self.newNode(.{ .vector_f = items });
            },
            .bool_ => {
                const v = self.advance();
                const b = v.src[0] == '1';
                return self.newNode(.{ .atom = K{ .boolean = b } });
            },
            .sym => {
                var vals = std.array_list.Managed([]const u8).init(self.alloc());
                while (self.cur().kind == .sym) {
                    try vals.append(self.advance().src[1..]); // strip backtick
                }
                const items = try vals.toOwnedSlice();
                if (items.len == 1) return self.newNode(.{ .sym_atom = items[0] });
                return self.newNode(.{ .sym_vec = items });
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    fn parseLambda(self: *Parser) ParseError!*Node {
        _ = try self.expect(.lbrace);
        var params: [][]const u8 = &.{};
        if (self.cur().kind == .lbracket) {
            _ = self.advance();
            var ps = std.array_list.Managed([]const u8).init(self.alloc());
            while (self.cur().kind == .name) {
                try ps.append(self.advance().src);
                if (self.cur().kind == .semi) _ = self.advance();
            }
            _ = try self.expect(.rbracket);
            params = try ps.toOwnedSlice();
        }
        self.skipNl();
        const body = try self.parseE();
        _ = try self.expect(.rbrace);
        return self.newNode(.{ .lambda = .{ .params = params, .body = body } });
    }

    fn parseSelect(self: *Parser) ParseError!*Node {
        _ = self.advance(); // consume select/update/delete
        self.skipNl();

        // Optional column list: name (`,` name)*
        var cols_list = std.array_list.Managed([]const u8).init(self.alloc());
        while (self.cur().kind == .name and self.peek(1).kind != .kw_from) {
            try cols_list.append(self.advance().src);
            if (self.cur().kind == .verb and self.cur().src[0] == ',') _ = self.advance();
        }
        const cols = try cols_list.toOwnedSlice();

        // 'from'
        if (self.cur().kind == .kw_from) _ = self.advance();

        // Table name
        const table_tok = try self.expect(.name);

        // Optional 'where'
        var where_node: ?*Node = null;
        if (self.cur().kind == .kw_where) {
            _ = self.advance();
            where_node = try self.parseE();
        }

        return self.newNode(.{ .select_q = .{
            .cols = if (cols.len > 0) cols else null,
            .table = table_tok.src,
            .where = where_node,
            .by = null,
        }});
    }
};

fn parseInt(s: []const u8) ParseError!i64 {
    return std.fmt.parseInt(i64, s, 10) catch return ParseError.BadLiteral;
}

fn parseFloat(s: []const u8) ParseError!f64 {
    return std.fmt.parseFloat(f64, s) catch return ParseError.BadLiteral;
}

test "parse integer atom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex.Lexer.tokenize(arena.allocator(), "42");
    var p = Parser.init(arena.allocator(), toks);
    defer p.deinit();
    const node = try p.parseExpr();
    try std.testing.expectEqual(@as(i64, 42), node.atom.long);
}

test "parse dyadic right-assoc" {
    // 2 + 3 * 4 should parse as 2 + (3 * 4)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex.Lexer.tokenize(arena.allocator(), "2 + 3 * 4");
    var p = Parser.init(arena.allocator(), toks);
    defer p.deinit();
    const node = try p.parseExpr();
    // node = dyadic(+, atom(2), dyadic(*, atom(3), atom(4)))
    try std.testing.expectEqual(NodeTag.dyadic, std.meta.activeTag(node.*));
    try std.testing.expectEqual(@as(u8, '+'), node.dyadic.verb);
    try std.testing.expectEqual(NodeTag.dyadic, std.meta.activeTag(node.dyadic.rhs.*));
    try std.testing.expectEqual(@as(u8, '*'), node.dyadic.rhs.dyadic.verb);
}

test "parse vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex.Lexer.tokenize(arena.allocator(), "1 2 3");
    var p = Parser.init(arena.allocator(), toks);
    defer p.deinit();
    const node = try p.parseExpr();
    try std.testing.expectEqual(NodeTag.vector_i, std.meta.activeTag(node.*));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, node.vector_i);
}

test "parse assign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex.Lexer.tokenize(arena.allocator(), "x: 42");
    var p = Parser.init(arena.allocator(), toks);
    defer p.deinit();
    const node = try p.parseExpr();
    try std.testing.expectEqual(NodeTag.assign, std.meta.activeTag(node.*));
    try std.testing.expectEqualStrings("x", node.assign.name);
}
