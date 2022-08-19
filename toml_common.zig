const std = @import("std");

pub const Toml = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMapUnmanaged(TomlValue) = .{},

    pub fn deinit(toml: *Toml) void {
        toml.root.deinit(toml.allocator);
    }
};

pub const TomlValue = union(enum) {
    boolean: bool,
};
