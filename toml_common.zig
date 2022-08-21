const std = @import("std");

pub const Toml = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMapUnmanaged(void) = .{},
    root: Value.Table = .{},

    pub fn deinit(toml: *Toml) void {
        deinitTable(toml.allocator, &toml.root);
        var ki = toml.strings.keyIterator();
        while (ki.next()) |key| toml.allocator.free(key.*);
        toml.strings.deinit(toml.allocator);
        toml.* = undefined;
    }

    pub fn getString(toml: *Toml, string: []const u8) std.mem.Allocator.Error![]const u8 {
        if (toml.strings.getKey(string)) |key| {
            return key;
        } else {
            const key = try toml.allocator.dupe(u8, string);
            try toml.strings.put(toml.allocator, key, {});
            return key;
        }
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

    const Table = std.StringHashMapUnmanaged(Value);

    // TODO don't expose in API
    pub fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .boolean, .integer, .float, .string => {},
            .list => allocator.free(value.list),
            .table => deinitTable(allocator, &value.table),
        }
        value.* = undefined;
    }
};

fn deinitTable(allocator: std.mem.Allocator, table: *Value.Table) void {
    var vi = table.valueIterator();
    while (vi.next()) |v| v.deinit(allocator);
    table.deinit(allocator);
}
