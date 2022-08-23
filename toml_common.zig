const std = @import("std");

pub const Toml = struct {
    allocator: std.mem.Allocator,
    root: Value.Table = .{},

    pub fn deinit(toml: *Toml) void {
        deinitTable(toml.allocator, &toml.root);
        toml.* = undefined;
    }

    pub fn get(toml: Toml, key: []const u8) ?Value {
        return toml.root.get(key);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    list: []const Value,
    table: Table,

    pub const Table = std.StringHashMapUnmanaged(Value);

    fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .boolean, .integer, .float => {},
            .string => allocator.free(value.string),
            .list => allocator.free(value.list),
            .table => deinitTable(allocator, &value.table),
        }
        value.* = undefined;
    }
};

fn deinitTable(allocator: std.mem.Allocator, table: *Value.Table) void {
    var i = table.iterator();
    while (i.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    table.deinit(allocator);
}
