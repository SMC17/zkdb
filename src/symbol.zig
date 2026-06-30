//! symbol — interned symbol table.

const std = @import("std");

pub const SymTable = struct {
    arena: std.heap.ArenaAllocator,
    by_str: std.StringHashMap(u32),
    by_id: std.array_list.Managed([]const u8),

    pub fn init(backing: std.mem.Allocator) SymTable {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .by_str = std.StringHashMap(u32).init(backing),
            .by_id = std.array_list.Managed([]const u8).init(backing),
        };
    }

    pub fn deinit(self: *SymTable) void {
        self.by_str.deinit();
        self.by_id.deinit();
        self.arena.deinit();
    }

    pub fn intern(self: *SymTable, s: []const u8) !u32 {
        if (self.by_str.get(s)) |id| return id;
        const id: u32 = @intCast(self.by_id.items.len);
        const owned = try self.arena.allocator().dupe(u8, s);
        try self.by_id.append(owned);
        try self.by_str.put(owned, id);
        return id;
    }

    pub fn resolve(self: *const SymTable, id: u32) []const u8 {
        return self.by_id.items[id];
    }

    pub fn count(self: *const SymTable) usize {
        return self.by_id.items.len;
    }
};

test "symbol intern + resolve" {
    var sym = SymTable.init(std.testing.allocator);
    defer sym.deinit();

    const a = try sym.intern("AAPL");
    const b = try sym.intern("GOOG");
    const a2 = try sym.intern("AAPL");

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
    try std.testing.expectEqualStrings("AAPL", sym.resolve(a));
    try std.testing.expectEqualStrings("GOOG", sym.resolve(b));
    try std.testing.expectEqual(@as(usize, 2), sym.count());
}
