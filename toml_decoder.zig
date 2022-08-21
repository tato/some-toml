const std = @import("std");
const common = @import("toml_common.zig");

pub fn decode(allocator: std.mem.Allocator, reader: anytype) DecodeError!common.Toml {
    var parser = try Parser(@TypeOf(reader)).init(allocator, reader);
    defer parser.deinit();

    const result = try parser.parse();

    return result;
}

pub const DecodeError = std.mem.Allocator.Error || error{
    io_error,
    invalid_newline,
    unexpected_eof,
    expected_equals,
    expected_newline,
    expected_value,
    unexpected_bare_key,
    duplicate_key,
    unexpected_multi_line_string,
    invalid_control_in_basic_string,
    invalid_newline_in_basic_string,
    zero_length_bare_key,
    invalid_escape_sequence,
    unexpected_character,
    invalid_char_in_unicode_escape_sequence,
    invalid_unicode_scalar_in_escape_sequence,
};

fn Parser(comptime Reader: type) type {
    return struct {
        const lookahead = 2;
        const Stream = std.io.PeekStream(.{ .Static = 2 }, Reader);

        allocator: std.mem.Allocator,

        stream: Stream,
        strings: std.ArrayListUnmanaged(u8) = .{},

        output: common.Toml,

        fn init(allocator: std.mem.Allocator, reader: Reader) !@This() {
            const output = common.Toml{ .allocator = allocator };
            const peekable = Stream.init(reader);
            var parser = @This(){ .allocator = allocator, .stream = peekable, .output = output };
            return parser;
        }

        fn deinit(parser: *@This()) void {
            parser.strings.deinit(parser.allocator);
            parser.* = undefined;
        }

        fn parse(parser: *@This()) !common.Toml {
            errdefer parser.output.deinit();

            while (true) {
                try parser.skipWhitespace();
                try parser.matchKeyValuePair();
                const found_newline = try parser.matchNewLine();

                const c = try parser.readByte();
                if (c) |b| {
                    if (!found_newline) return error.expected_newline else try parser.stream.putBackByte(b);
                } else break;
            }

            return parser.output;
        }

        fn matchKeyValuePair(parser: *@This()) !void {
            var key: []const u8 = undefined;
            var value: common.Value = undefined;

            {
                const c = (try parser.readByte()) orelse return;

                if (c == '\r' or c == '\n') {
                    try parser.stream.putBackByte(c);
                    return;
                }

                if (c == '"') {
                    const bounds = try parser.tokenizeBasicString(.disallow_multi);
                    key = try parser.output.allocator.dupe(u8, parser.getString(bounds));
                } else if (c == '\'') {
                    const bounds = try parser.tokenizeLiteralString(.disallow_multi);
                    key = try parser.output.allocator.dupe(u8, parser.getString(bounds));
                } else {
                    try parser.stream.putBackByte(c);
                    const bounds = try parser.tokenizeBareKey();
                    key = try parser.output.allocator.dupe(u8, parser.getString(bounds));
                }
            }
            errdefer parser.output.allocator.free(key);

            {
                try parser.skipWhitespace();
                const c = (try parser.readByte()) orelse return error.unexpected_eof;
                if (c != '=') return error.expected_equals;
                try parser.skipWhitespace();
            }

            {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (c == '"') {
                    const bounds = try parser.tokenizeBasicString(.allow_multi);
                    value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(bounds)) };
                } else if (c == '\'') {
                    const bounds = try parser.tokenizeLiteralString(.allow_multi);
                    value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(bounds)) };
                } else else_prong: {
                    if (std.ascii.isDigit(c)) {
                        try parser.stream.putBackByte(c);
                        value = try parser.tokenizeNumber();
                        break :else_prong;
                    }

                    if (c == '-' or c == '+') {
                        const d = try parser.readByte();
                        if (d != null and std.ascii.isDigit(d.?)) {
                            try parser.stream.putBackByte(d.?);
                            try parser.stream.putBackByte(c);
                            value = try parser.tokenizeNumber();
                            break :else_prong;
                        }
                        if (d) |b| try parser.stream.putBackByte(b);
                    }

                    try parser.stream.putBackByte(c);

                    const bounds = try (parser.tokenizeBareKey() catch |e| switch (e) {
                        error.zero_length_bare_key => error.expected_value,
                        else => e,
                    });
                    const string = parser.getString(bounds);
                    if (std.mem.eql(u8, "true", string)) {
                        value = .{ .boolean = true };
                    } else if (std.mem.eql(u8, "false", string)) {
                        value = .{ .boolean = false };
                    } else {
                        return error.unexpected_bare_key;
                    }
                }
            }
            errdefer value.deinit(parser.output.allocator);

            const gop = try parser.output.root.getOrPut(parser.output.allocator, key);
            if (gop.found_existing) {
                return error.duplicate_key;
            } else {
                gop.value_ptr.* = value;
            }
            try parser.skipWhitespace();
        }

        fn matchNewLine(parser: *@This()) !bool {
            const nl = (try parser.readByte()) orelse return false;
            if (nl == '\n') return true;
            if (nl == '\r') {
                const maybe_nlnl = try parser.readByte();
                if (maybe_nlnl) |nlnl| {
                    return if (nlnl == '\n') true else error.invalid_newline;
                } else return error.unexpected_eof;
            }
            try parser.stream.putBackByte(nl);
            return false;
        }

        fn readByte(parser: *@This()) !?u8 {
            return parser.stream.reader().readByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return error.io_error,
            };
        }

        fn isBareKeyChar(c: u8) bool {
            return std.ascii.isAlNum(c) or c == '_' or c == '-';
        }

        fn tokenizeBareKey(parser: *@This()) !StringBounds {
            const start = parser.strings.items.len;

            while (true) {
                const c = try parser.readByte();
                if (c) |b| {
                    if (isBareKeyChar(b)) {
                        try parser.strings.append(parser.allocator, b);
                    } else {
                        // we put back the unexpected byte: it's part of the next token
                        try parser.stream.putBackByte(b);
                        break;
                    }
                } else {
                    // if readByte returns null we have reached eof
                    break;
                }
            }

            const len = parser.strings.items.len - start;
            if (len == 0) return error.zero_length_bare_key;
            return StringBounds{ .start = start, .len = len };
        }

        const AllowMulti = enum(u1) { disallow_multi, allow_multi };

        fn tokenizeBasicString(parser: *@This(), allow_multi: AllowMulti) !StringBounds {
            const start = parser.strings.items.len;

            const is_multi = check_multi: {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;
                if (c == '"') check_multi_inner: {
                    const cc = (try parser.readByte()) orelse break :check_multi_inner;
                    if (cc == '"') break :check_multi true;
                    try parser.stream.putBackByte(cc);
                }
                try parser.stream.putBackByte(c);
                break :check_multi false;
            };

            if (is_multi and allow_multi == .disallow_multi) return error.unexpected_multi_line_string;

            if (is_multi) trim_newline: {
                const trim_a = (try parser.readByte()) orelse break :trim_newline;
                if (trim_a == '\n') break :trim_newline;
                if (trim_a == '\r') trim_newline_inner: {
                    const trim_b = (try parser.readByte()) orelse break :trim_newline_inner;
                    if (trim_b == '\n') break :trim_newline;
                    try parser.stream.putBackByte(trim_b);
                }
                try parser.stream.putBackByte(trim_a);
            }

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (is_multi) {
                    if (c == '"') check_end: {
                        const next = (try parser.readByte()) orelse break :check_end;
                        if (next == '"') inner_check_end: {
                            const nextnext = (try parser.readByte()) orelse break :inner_check_end;
                            if (nextnext == '"') break;
                            try parser.stream.putBackByte(nextnext);
                        }
                        try parser.stream.putBackByte(next);
                    }
                } else {
                    if (c == '"') break;
                }

                if (is_multi) {
                    if (std.ascii.isCntrl(c) and c != '\t' and c != '\n' and c != '\r') return error.invalid_control_in_basic_string;
                } else {
                    if (c == '\n') return error.invalid_newline_in_basic_string;
                    if (std.ascii.isCntrl(c) and c != '\t') return error.invalid_control_in_basic_string;
                }

                if (c == '\\') {
                    c = (try parser.readByte()) orelse return error.unexpected_eof;
                    switch (c) {
                        '"', '\\' => try parser.strings.append(parser.allocator, c),
                        'b' => try parser.strings.append(parser.allocator, std.ascii.control_code.BS),
                        't' => try parser.strings.append(parser.allocator, '\t'),
                        'n' => try parser.strings.append(parser.allocator, '\n'),
                        'f' => try parser.strings.append(parser.allocator, std.ascii.control_code.FF),
                        'r' => try parser.strings.append(parser.allocator, '\r'),
                        'u' => try parser.tokenizeUnicodeSequence(4),
                        'U' => try parser.tokenizeUnicodeSequence(8),
                        ' ', '\t', '\r', '\n' => {
                            if (!is_multi) return error.invalid_escape_sequence;

                            var found_the_newline = c == '\n';
                            if (c == '\r') {
                                c = (try parser.readByte()) orelse return error.unexpected_eof;
                                if (c == '\n') {
                                    found_the_newline = true;
                                } else {
                                    return error.unexpected_character;
                                }
                            }
                            while (true) {
                                c = (try parser.readByte()) orelse return error.unexpected_eof;
                                switch (c) {
                                    ' ', '\t' => {},
                                    '\n' => found_the_newline = true,
                                    '\r' => {
                                        c = (try parser.readByte()) orelse return error.unexpected_eof;
                                        if (c == '\n') {
                                            found_the_newline = true;
                                        } else {
                                            return error.unexpected_character;
                                        }
                                    },
                                    else => {
                                        if (found_the_newline) {
                                            try parser.stream.putBackByte(c);
                                            break;
                                        } else {
                                            std.log.err("Found '{c}' before finding the newline while parsing line ending backslash.", .{c});
                                            return error.invalid_escape_sequence;
                                        }
                                    },
                                }
                            }
                        },
                        else => return error.invalid_escape_sequence,
                    }
                } else {
                    try parser.strings.append(parser.allocator, c);
                }
            }

            return StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeLiteralString(parser: *@This(), allow_multi: AllowMulti) !StringBounds {
            const start = parser.strings.items.len;

            const is_multi = check_multi: {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;
                if (c == '\'') check_multi_inner: {
                    const cc = (try parser.readByte()) orelse break :check_multi_inner;
                    if (cc == '\'') break :check_multi true;
                    try parser.stream.putBackByte(cc);
                }
                try parser.stream.putBackByte(c);
                break :check_multi false;
            };

            if (is_multi and allow_multi == .disallow_multi) return error.unexpected_multi_line_string;

            if (is_multi) {
                trim_newline: {
                    const trim_a = (try parser.readByte()) orelse break :trim_newline;
                    if (trim_a == '\n') break :trim_newline;
                    if (trim_a == '\r') inner_trim_newline: {
                        const trim_b = (try parser.readByte()) orelse break :inner_trim_newline;
                        if (trim_b == '\n') break :trim_newline;
                        try parser.stream.putBackByte(trim_b);
                    }
                    try parser.stream.putBackByte(trim_a);
                }
            }

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (is_multi) {
                    if (std.ascii.isCntrl(c) and c != '\t' and c != '\n' and c != '\r') return error.invalid_control_in_basic_string;
                } else {
                    if (c == '\n') return error.invalid_newline_in_basic_string;
                    if (std.ascii.isCntrl(c) and c != '\t') return error.invalid_control_in_basic_string;
                }

                if (is_multi) {
                    if (c == '\'') check_end: {
                        const next = (try parser.readByte()) orelse break :check_end;
                        if (next == '\'') inner_check_end: {
                            const nextnext = (try parser.readByte()) orelse break :inner_check_end;
                            if (nextnext == '\'') break;
                            try parser.stream.putBackByte(nextnext);
                        }
                        try parser.stream.putBackByte(next);
                    }
                } else {
                    if (c == '\'') break;
                }

                try parser.strings.append(parser.allocator, c);
            }

            return StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeUnicodeSequence(parser: *@This(), comptime len: u8) !void {
            var digits: [len]u8 = undefined;
            for (digits) |*d| {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;
                if (std.ascii.isDigit(c) or c >= 'a' and c <= 'f' or c >= 'A' and c <= 'F') {
                    d.* = c;
                } else {
                    return error.invalid_char_in_unicode_escape_sequence;
                }
            }
            const scalar = std.fmt.parseInt(u21, &digits, 16) catch |e| switch (e) {
                error.Overflow => return error.invalid_unicode_scalar_in_escape_sequence,
                error.InvalidCharacter => unreachable,
            };
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(scalar, &utf8_buf) catch |e| switch (e) {
                error.Utf8CannotEncodeSurrogateHalf,
                error.CodepointTooLarge,
                => return error.invalid_unicode_scalar_in_escape_sequence,
            };
            try parser.strings.appendSlice(parser.allocator, utf8_buf[0..utf8_len]);
        }

        fn tokenizeNumber(parser: *@This()) !common.Value {
            const sign_char = (try parser.readByte()) orelse return error.unexpected_eof;
            const negative = if (sign_char == '-') true else if (sign_char == '+') false else else_prong: {
                try parser.stream.putBackByte(sign_char);
                break :else_prong false;
            };

            const base: i64 = base: {
                const base_zero = (try parser.readByte()) orelse return error.unexpected_eof;
                if (base_zero == '0') {
                    const maybe_base_char = try parser.readByte();
                    if (maybe_base_char) |base_char| {
                        switch (base_char) {
                            'x' => break :base 16,
                            'o' => break :base 8,
                            'b' => break :base 2,
                            else => {},
                        }
                        try parser.stream.putBackByte(base_char);
                    }
                }
                try parser.stream.putBackByte(base_zero);
                break :base 10;
            };

            const valid_fn = &switch (base) {
                16 => isHexDigit,
                10 => std.ascii.isDigit,
                8 => isOctalDigit,
                2 => isBinDigit,
                else => unreachable,
            };

            const value_fn = &switch (base) {
                16 => hexValue,
                10, 8, 2 => digitValue,
                else => unreachable,
            };

            var number_buf = std.ArrayList(u8).init(parser.allocator);
            defer number_buf.deinit();

            var c = (try parser.readByte()) orelse return error.unexpected_eof;
            std.debug.assert(valid_fn(c));
            while (true) {
                if (valid_fn(c)) {
                    try number_buf.append(c);
                } else if (c != '_') {
                    try parser.stream.putBackByte(c);
                    break;
                }
                c = (try parser.readByte()) orelse break;
            }

            var scale: i64 = std.math.pow(i64, base, @intCast(i64, number_buf.items.len));
            var number: i64 = 0;
            for (number_buf.items) |n| {
                scale = @divExact(scale, base);
                number += value_fn(n) * scale;
            }

            if (negative) {
                number = -number;
            }

            return common.Value{ .integer = number };
        }

        fn hexValue(c: u8) u8 {
            return if (std.ascii.isDigit(c)) c - '0' else std.ascii.toLower(c) - 'a' + 10;
        }

        fn digitValue(c: u8) u8 {
            return c - '0';
        }

        fn isHexDigit(c: u8) bool {
            const lower_c = std.ascii.toLower(c);
            return std.ascii.isDigit(c) or (lower_c >= 'a' and lower_c <= 'f');
        }

        fn isOctalDigit(c: u8) bool {
            return c >= '0' and c <= '7';
        }

        fn isBinDigit(c: u8) bool {
            return c == '0' or c == '1';
        }

        fn skipComment(parser: *@This()) !void {
            while (true) {
                const found_newline = try parser.matchNewLine();
                if (found_newline) {
                    try parser.stream.putBackByte('\n');
                    break;
                } else {
                    const c = try parser.readByte();
                    if (c == null) break;
                }
            }
        }

        fn skipWhitespace(parser: *@This()) !void {
            var c = (try parser.readByte()) orelse return;
            while (c == ' ' or c == '\t') : (c = (try parser.readByte()) orelse return) {}
            if (c == '#') try parser.skipComment() else try parser.stream.putBackByte(c);
        }

        fn getString(parser: *@This(), bounds: StringBounds) []const u8 {
            std.debug.assert(parser.strings.items.len >= bounds.start + bounds.len);
            return parser.strings.items[bounds.start .. bounds.start + bounds.len];
        }

        const StringBounds = struct {
            start: usize,
            len: usize,
        };
    };
}

fn debugPrintAllTokens(allocator: std.mem.Allocator, reader: anytype) !void {
    std.debug.print("\nPRINTING ALL TOKENS:\n", .{});

    var parser = try Parser(@TypeOf(reader)).init(allocator, reader);
    defer parser.deinit();

    while (parser.current.kind != .eof) {
        std.debug.print("FOUND: {any}", .{parser.current.kind});
        switch (parser.current.val) {
            .none => {},
            .string => std.debug.print(" [{s}]", .{parser.getString(parser.current.val.string)}),
        }
        std.debug.print("\n", .{});

        try parser.advance();
    }
}

test "comment" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/comment.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "# This is not a comment", toml.get("another").?.string);
}

test "invalid 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 1.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.unexpected_eof, err);
}

test "invalid 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 2.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.expected_newline, err);
}

test "invalid 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 3.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.zero_length_bare_key, err);
}

test "invalid 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 4.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.expected_value, err);
}

test "bare keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/bare keys.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("bare_key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("bare-key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("1234").?.string);
}

test "quoted keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/quoted keys.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("127.0.0.1").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("character encoding").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("ʎǝʞ").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("key2").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("quoted \"value\"").?.string);
}

test "empty keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 1.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "empty keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 2.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "dotted keys 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 1.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "dotted keys 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 2.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "repeat keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 1.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 2.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 3" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 3.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "repeat keys 4" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 4.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.repeated_key, err);
}

test "out of order 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 1.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "out of order 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 2.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "dotted keys not floats" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys not floats.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/basic strings 1.toml"));

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "I'm a string. \"You can quote me\". Name\tJos\u{00E9}\nLocation\tSF.", toml.get("str").?.string);
}

test "multi-line basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "Roses are red\nViolets are blue", toml.get("str1").?.string);
}

test "multi-line basic strings 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8,
        \\Here are two quotation marks: "". Simple enough.
    , toml.get("str4").?.string);
    try std.testing.expectEqualSlices(u8,
        \\Here are three quotation marks: """.
    , toml.get("str5").?.string);
    try std.testing.expectEqualSlices(u8,
        \\Here are fifteen quotation marks: """"""""""""""".
    , toml.get("str6").?.string);
}

test "multi-line basic strings line ending backslash" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings line ending backslash.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    const expect = "The quick brown fox jumps over the lazy dog.";
    try std.testing.expectEqualSlices(u8, expect, toml.get("str1").?.string);
    try std.testing.expectEqualSlices(u8, expect, toml.get("str2").?.string);
    try std.testing.expectEqualSlices(u8, expect, toml.get("str3").?.string);
}

test "literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/literal strings 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "C:\\Users\\nodejs\\templates", toml.get("winpath").?.string);
    try std.testing.expectEqualSlices(u8, "\\\\ServerX\\admin$\\system32\\", toml.get("winpath2").?.string);
    try std.testing.expectEqualSlices(u8, "Tom \"Dubs\" Preston-Werner", toml.get("quoted").?.string);
    try std.testing.expectEqualSlices(u8, "<\\i\\c*\\s*>", toml.get("regex").?.string);
}

test "multi-line literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line literal strings 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "I [dw]on't need \\d{2} apples", toml.get("regex2").?.string);
    try std.testing.expectEqualSlices(u8,
        \\The first newline is
        \\trimmed in raw strings.
        \\   All other whitespace
        \\   is preserved.
        \\
    , toml.get("lines").?.string);
}

test "multi-line literal strings 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line literal strings 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8,
        \\Here are fifteen quotation marks: """""""""""""""
    , toml.get("quot15").?.string);
    try std.testing.expectEqualSlices(u8, "Here are fifteen apostrophes: '''''''''''''''", toml.get("apos15").?.string);
}

test "integers 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(99 == toml.get("int1").?.integer);
    try std.testing.expect(42 == toml.get("int2").?.integer);
    try std.testing.expect(0 == toml.get("int3").?.integer);
    try std.testing.expect(-17 == toml.get("int4").?.integer);
    try std.testing.expect(-11 == toml.get("-11").?.integer);
}

test "integers 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(1_000 == toml.get("int5").?.integer);
    try std.testing.expect(5_349_221 == toml.get("int6").?.integer);
    try std.testing.expect(53_49_221 == toml.get("int7").?.integer);
    try std.testing.expect(1_2_3_4_5 == toml.get("int8").?.integer);
}

test "integers 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 3.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(0xDEADBEEF == toml.get("hex1").?.integer);
    try std.testing.expect(0xdeadbeef == toml.get("hex2").?.integer);
    try std.testing.expect(0xdead_beef == toml.get("hex3").?.integer);
    try std.testing.expect(0o01234567 == toml.get("oct1").?.integer);
    try std.testing.expect(0o755 == toml.get("oct2").?.integer);
    try std.testing.expect(0b11010110 == toml.get("bin1").?.integer);
}

test "floats 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats 3" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 3.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats invalid 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats invalid 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "booleans 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/booleans 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(true, toml.get("bool1").?.boolean);
    try std.testing.expectEqual(false, toml.get("bool2").?.boolean);
}

test "offset date time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "offset date time 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local date time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date time 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local date 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local time 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "arrays 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 1.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "arrays 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}
