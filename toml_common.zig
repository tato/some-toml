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

    pub fn format(value: Toml, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatTable(value.root, fmt, options, writer);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: std.ArrayListUnmanaged(Value),
    table: Table,

    pub const Table = std.StringHashMapUnmanaged(Value);

    fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .boolean, .integer, .float => {},
            .string => allocator.free(value.string),
            .array => {
                for (value.array.items) |*item| item.deinit(allocator);
                value.array.deinit(allocator);
            },
            .table => deinitTable(allocator, &value.table),
        }
        value.* = undefined;
    }

    pub fn format(value: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .string => try writer.writeAll(value.string),
            .integer => try writer.print("{d}", .{value.integer}),
            .float => try writer.print("{d:.2}", .{value.float}),
            .boolean => try writer.print("{}", .{value.boolean}),
            .array => {
                try writer.writeAll("[\n");
                for (value.array.items) |elem| {
                    try writer.print("{}", .{elem});
                    try writer.writeAll(",\n");
                }
                try writer.writeAll("]");
            },
            .table => try formatTable(value.table, fmt, options, writer),
        }
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

pub fn formatTable(value: Value.Table, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try writer.writeAll("{\n");
    var i = value.iterator();
    while (i.next()) |entry| {
        // try writer.writeAll(entry.key_ptr.*);
        // try writer.writeAll(" = ");
        // try entry.value_ptr.format(fmt, options, writer);
        // try writer.writeAll("\n");
        try writer.print("{s} = {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try writer.writeAll("}");
}
