const std = @import("std");

pub const Toml = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMapUnmanaged(Value) = .{},

    pub fn deinit(toml: *Toml) void {
        var vi = toml.root.valueIterator();
        while (vi.next()) |v| v.deinit(toml.allocator);
        var ki = toml.root.keyIterator();
        while (ki.next()) |k| toml.allocator.free(k.*);
        toml.root.deinit(toml.allocator);
    }

    pub fn get(toml: Toml, key: []const u8) ?Value {
        return toml.root.get(key);
    }
};

pub const Value = union(enum) {
    boolean: bool,
    string: []const u8,

    fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .boolean => {},
            .string => allocator.free(value.string),
        }
        value.* = undefined;
    }
};
