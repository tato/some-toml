const std = @import("std");

pub const Toml = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMapUnmanaged(TomlValue) = .{},

    pub fn deinit(toml: *Toml) void {
        var ki = toml.root.keyIterator();
        while (ki.next()) |k| toml.allocator.free(k.*);
        toml.root.deinit(toml.allocator);
    }
};

pub const TomlValue = union(enum) {
    boolean: bool,
};
