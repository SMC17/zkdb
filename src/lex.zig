//! lex — q/k tokenizer.
//!
//! Token kinds and their src-slice interpretation:
//!   .int    → src = decimal digits (may be negative: "-3")
//!   .float  → src = decimal with '.' or 'e'
//!   .bool_  → src = "0b" or "1b"
//!   .sym    → src = everything after the backtick (may be empty)
//!   .string → src = content inside double quotes (unescaped)
//!   .name   → src = identifier
//!   .verb   → src = single-char verb: + - * % & | < > = ~ ! # , ^ @ ? _ $
//!   .adverb → src = adverb: ' / \ ': /: \:
//!   .colon  → ":"
//!   .dcolon → "::"

const std = @import("std");

pub const TokKind = enum(u8) {
    int, float, bool_, sym, char, string, name,
    verb, adverb,
    lparen, rparen, lbracket, rbracket, lbrace, rbrace,
    semi, colon, dcolon, nl,
    kw_select, kw_update, kw_delete, kw_exec,
    kw_from, kw_where, kw_by,
    eof,
};

pub const Tok = struct {
    kind: TokKind,
    src: []const u8,
    pos: usize,
};

const VERBS = "+-*%&|<>=~!#,^@?_$";

const KEYWORDS = std.StaticStringMap(TokKind).initComptime(.{
    .{ "select", .kw_select },
    .{ "update", .kw_update },
    .{ "delete", .kw_delete },
    .{ "exec",   .kw_exec   },
    .{ "from",   .kw_from   },
    .{ "where",  .kw_where  },
    .{ "by",     .kw_by     },
});

pub const Lexer = struct {
    src: []const u8,
    pos: usize,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0 };
    }

    fn cur(self: *Lexer) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
    }

    fn peek(self: *Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    fn skipSpace(self: *Lexer) void {
        while (self.cur()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') self.advance() else break;
        }
    }

    fn makeToken(self: *Lexer, kind: TokKind, start: usize) Tok {
        return .{ .kind = kind, .src = self.src[start..self.pos], .pos = start };
    }

    pub fn next(self: *Lexer) Tok {
        self.skipSpace();
        const start = self.pos;

        const c = self.cur() orelse return .{ .kind = .eof, .src = "", .pos = start };

        // Newline
        if (c == '\n') { self.advance(); return self.makeToken(.nl, start); }

        // Comment: / at start or after space
        if (c == '/' and (start == 0 or self.src[start - 1] == ' ' or self.src[start-1] == '\n' or self.src[start-1] == '\t')) {
            // Line comment — skip to end
            while (self.cur()) |ch| { self.advance(); if (ch == '\n') break; }
            return self.next();
        }

        // Symbol: `name or ` (empty)
        if (c == '`') {
            self.advance();
            while (self.cur()) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') self.advance() else break;
            }
            return self.makeToken(.sym, start);
        }

        // String/char: "..."
        if (c == '"') {
            self.advance();
            const content_start = self.pos;
            while (self.cur()) |ch| {
                if (ch == '"') break;
                if (ch == '\\') { self.advance(); } // skip escaped char
                self.advance();
            }
            const tok = Tok{ .kind = if (self.pos - content_start == 1) .char else .string,
                             .src = self.src[content_start..self.pos], .pos = start };
            if (self.cur() == '"') self.advance(); // consume closing quote
            return tok;
        }

        // Negative number: -digit (no space)
        if (c == '-') {
            if (self.peek(1)) |nc| {
                if (std.ascii.isDigit(nc)) {
                    self.advance(); // consume -
                    return self.lexNumber(start);
                }
            }
        }

        // Number
        if (std.ascii.isDigit(c)) {
            return self.lexNumber(start);
        }

        // Name or keyword
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '.') {
            self.advance();
            while (self.cur()) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') self.advance() else break;
            }
            const word = self.src[start..self.pos];
            if (KEYWORDS.get(word)) |kw| return .{ .kind = kw, .src = word, .pos = start };
            return .{ .kind = .name, .src = word, .pos = start };
        }

        // Punctuation
        self.advance();
        switch (c) {
            '(' => return self.makeToken(.lparen, start),
            ')' => return self.makeToken(.rparen, start),
            '[' => return self.makeToken(.lbracket, start),
            ']' => return self.makeToken(.rbracket, start),
            '{' => return self.makeToken(.lbrace, start),
            '}' => return self.makeToken(.rbrace, start),
            ';' => return self.makeToken(.semi, start),
            ':' => {
                if (self.cur() == ':') { self.advance(); return self.makeToken(.dcolon, start); }
                return self.makeToken(.colon, start);
            },
            // Adverbs
            '\'' => {
                if (self.cur() == ':') { self.advance(); return self.makeToken(.adverb, start); }
                return self.makeToken(.adverb, start);
            },
            '/' => {
                if (self.cur() == ':') { self.advance(); return self.makeToken(.adverb, start); }
                return self.makeToken(.adverb, start);
            },
            '\\' => {
                if (self.cur() == ':') { self.advance(); return self.makeToken(.adverb, start); }
                return self.makeToken(.adverb, start);
            },
            else => {
                // Check verb
                if (std.mem.indexOfScalar(u8, VERBS, c) != null) {
                    return self.makeToken(.verb, start);
                }
                return self.makeToken(.name, start); // fallback
            },
        }
    }

    fn lexNumber(self: *Lexer, start: usize) Tok {
        var is_float = false;
        while (self.cur()) |c| {
            if (std.ascii.isDigit(c)) { self.advance(); }
            else if (c == '.' and !is_float) {
                if (self.peek(1)) |nc| {
                    if (std.ascii.isDigit(nc)) { is_float = true; self.advance(); }
                    else break;
                } else break;
            }
            else if ((c == 'e' or c == 'E') and !is_float) {
                is_float = true; self.advance();
                if (self.cur() == '+' or self.cur() == '-') self.advance();
            }
            else if (c == 'b') { // boolean suffix
                self.advance();
                return self.makeToken(.bool_, start);
            }
            else if (c == 'j') { self.advance(); break; } // long suffix
            else if (c == 'f') { is_float = true; self.advance(); break; }
            else break;
        }
        return self.makeToken(if (is_float) .float else .int, start);
    }

    pub fn tokenize(allocator: std.mem.Allocator, src: []const u8) ![]Tok {
        var self = Lexer.init(src);
        var toks = std.array_list.Managed(Tok).init(allocator);
        while (true) {
            const t = self.next();
            try toks.append(t);
            if (t.kind == .eof) break;
        }
        return toks.toOwnedSlice();
    }
};

test "lex basic tokens" {
    const toks = try Lexer.tokenize(std.testing.allocator, "2 + 3 * 4");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokKind.int,  toks[0].kind);
    try std.testing.expectEqual(TokKind.verb, toks[1].kind);
    try std.testing.expectEqual(TokKind.int,  toks[2].kind);
    try std.testing.expectEqual(TokKind.verb, toks[3].kind);
    try std.testing.expectEqual(TokKind.int,  toks[4].kind);
}

test "lex symbols" {
    const toks = try Lexer.tokenize(std.testing.allocator, "`AAPL `GOOG");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokKind.sym, toks[0].kind);
    try std.testing.expectEqualStrings("`AAPL", toks[0].src);
}

test "lex negative int" {
    const toks = try Lexer.tokenize(std.testing.allocator, "-42");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokKind.int, toks[0].kind);
    try std.testing.expectEqualStrings("-42", toks[0].src);
}

test "lex float" {
    const toks = try Lexer.tokenize(std.testing.allocator, "3.14 -2.5");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokKind.float, toks[0].kind);
    try std.testing.expectEqual(TokKind.float, toks[1].kind);
}

test "lex keywords" {
    const toks = try Lexer.tokenize(std.testing.allocator, "select from where by");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokKind.kw_select, toks[0].kind);
    try std.testing.expectEqual(TokKind.kw_from,   toks[1].kind);
    try std.testing.expectEqual(TokKind.kw_where,  toks[2].kind);
    try std.testing.expectEqual(TokKind.kw_by,     toks[3].kind);
}
