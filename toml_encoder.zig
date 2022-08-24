const std = @import("std");

// https://toml.io/en/v1.0.0#spec

pub fn stringify(comptime T: type, val: T, writer: anytype) !void {
    const ti = @typeInfo(T);
    comptime {
        std.debug.assert(ti == .Struct);
    }

    inline for (ti.Struct.fields) |field| {
        if (comptime @typeInfo(field.field_type) != .Struct and !isArrayOfTables(field.field_type)) {
            try writeKey(field.name, writer);
            try writer.writeAll(" = ");
            try writeValue(@field(val, field.name), writer);
            try writer.writeByte('\n');
        }
    }

    inline for (ti.Struct.fields) |field| {
        if (comptime @typeInfo(field.field_type) == .Struct) {
            try writer.writeByte('[');
            try writeKey(field.name, writer);
            try writer.writeAll("]\n");
            try writeTable(@field(val, field.name), writer);
        }
    }

    inline for (ti.Struct.fields) |field| {
        if (comptime isArrayOfTables(field.field_type)) {
            for (@field(val, field.name)) |elem| {
                try writer.writeAll("[[");
                try writeKey(field.name, writer);
                try writer.writeAll("]]\n");
                try writeTable(elem, writer);
            }
        }
    }
}

fn isBareKey(string: []const u8) bool {
    if (string.len == 0) return false;
    for (string) |c| {
        if (!std.ascii.isAlNum(c) and c != '_' and c != '-') {
            return false;
        }
    }
    return true;
}

fn isArrayOfTables(comptime T: type) bool {
    comptime {
        const ti = @typeInfo(T);
        const is_array = ti == .Array or std.meta.trait.isSlice(T);
        return is_array and @typeInfo(std.meta.Elem(T)) == .Struct;
    }
}

fn writeKey(string: []const u8, writer: anytype) !void {
    if (isBareKey(string)) {
        try writer.writeAll(string);
    } else {
        try writeString(string, writer);
    }
}

fn writeValue(val: anytype, writer: anytype) !void {
    const T = @TypeOf(val);
    const ti = @typeInfo(T);

    if (comptime std.meta.trait.isIntegral(T)) {
        try writer.print("{d}", .{val});
    } else if (comptime std.meta.trait.isFloat(T)) {
        try writeFloat(val, writer);
    } else if (comptime std.meta.trait.isZigString(T)) {
        // TODO incomplete, only accepts slices
        try writeString(val, writer);
    } else if (T == bool) {
        try writer.writeAll(if (val) "true" else "false");
    } else if (ti == .Array or std.meta.trait.isSlice(T)) {
        try writeArray(val, writer);
    } else {
        // TODO offset date-time
        // TODO local date-time
        // TODO local date
        // TODO local time
        // TODO inline table
        @compileLog("writeValue not implemented for type ", T);
    }
}

fn writeFloat(x: anytype, writer: anytype) !void {
    comptime std.debug.assert(std.meta.trait.isFloat(@TypeOf(x)));

    if (std.math.isNan(x)) {
        try writer.writeAll("nan");
    } else if (std.math.isPositiveInf(x)) {
        try writer.writeAll("+inf");
    } else if (std.math.isNegativeInf(x)) {
        try writer.writeAll("-inf");
    } else if (@rem(x, 1.0) == 0) {
        try writer.print("{d}.0", .{x});
    } else {
        try writer.print("{d}", .{x});
    }
}

fn writeString(string: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < string.len) : (i += 1) {
        const c = string[i];
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x8 => try writer.writeAll("\\b"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            0xC => try writer.writeAll("\\f"),
            '\r' => try writer.writeAll("\\r"),
            else => {
                if (std.ascii.isCntrl(c)) {
                    const utf8_len = try std.unicode.utf8ByteSequenceLength(c);
                    const utf8_int = try std.unicode.utf8Decode(string[i .. i + utf8_len]);
                    try writer.print("\\U{x:0>8}", .{utf8_int});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeArray(arr: anytype, writer: anytype) !void {
    try writer.writeAll("[ ");
    for (arr) |val, i| {
        try writeValue(val, writer);
        if (i != arr.len - 1)
            try writer.writeAll(", ");
    }
    try writer.writeAll(" ]");
}

fn writeTable(table: anytype, writer: anytype) !void {
    const ti: std.builtin.Type = @typeInfo(@TypeOf(table));
    inline for (ti.Struct.fields) |field| {
        try writeKey(field.name, writer);
        try writer.writeAll(" = ");
        try writeValue(@field(table, field.name), writer);
        try writer.writeByte('\n');
    }
}
