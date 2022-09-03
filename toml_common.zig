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

    pub fn format(value: Table, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        try writer.writeAll("{\n");

        var i = value.table.iterator();
        while (i.next()) |item| {
            try writer.print("{s} = {},\n", .{ item.key_ptr.*, item.value_ptr.* });
        }

        try writer.writeAll("}\n");
    }
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    offset_datetime: OffsetDateTime,
    local_datetime: LocalDateTime,
    local_date: LocalDate,
    local_time: LocalTime,
    array: std.ArrayListUnmanaged(Value),
    table: Table,

    fn deinit(value: *Value, allocator: std.mem.Allocator) void {
        switch (value.*) {
            .string => allocator.free(value.string),
            .array => {
                for (value.array.items) |*item| item.deinit(allocator);
                value.array.deinit(allocator);
            },
            .table => value.table.deinit(allocator),
            else => {},
        }
        value.* = undefined;
    }

    pub fn format(value: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (value) {
            .boolean => try writer.print("{}", .{value.boolean}),
            .integer => try writer.print("{d}", .{value.integer}),
            .float => try writer.print("{d}", .{value.float}),
            .string => try writer.print("\"{s}\"", .{value.string}),
            .offset_datetime => {
                const dt = value.offset_datetime;
                try writer.print("{} {} XX", .{ dt.date, dt.time });
            },
            .local_datetime => {
                const dt = value.local_datetime;
                try writer.print("{} {}", .{ dt.date, dt.time });
            },
            .local_date => {
                const d = value.local_date;
                try writer.print("{d}-{d:02}-{d:02}", .{ d.year, d.month, d.day });
            },
            .local_time => {
                const t = value.local_time;
                try writer.print(
                    "{d:02}:{d:02}:{d:02}.{d:03}",
                    .{ t.hour, t.minute, t.second, t.millisecond },
                );
            },
            .array => {
                try writer.writeAll("[\n");
                for (value.array.items) |item| {
                    try writer.print("{},", .{item});
                }
                try writer.writeAll("]\n");
            },
            .table => try value.table.format(fmt, options, writer),
        }
    }
};

pub const OffsetDateTime = struct {
    date: LocalDate,
    time: LocalTime,
    tz: void,
};
pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};
pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};
pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};
