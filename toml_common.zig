const std = @import("std");

pub const Table = struct {
    table: std.StringHashMapUnmanaged(Value) = .{},

    pub fn deinit(table: *Table, allocator: std.mem.Allocator) void {
        var i = table.table.iterator();
        while (i.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        table.table.deinit(allocator);
        table.* = undefined;
    }

    pub fn get(table: *const Table, key: []const u8) ?Value {
        return table.table.get(key);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: std.ArrayListUnmanaged(Value),
    table: Table,

    fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .boolean, .integer, .float => {},
            .string => allocator.free(value.string),
            .array => {
                for (value.array.items) |*item| item.deinit(allocator);
                value.array.deinit(allocator);
            },
            .table => value.table.deinit(allocator),
        }
        value.* = undefined;
    }
};
