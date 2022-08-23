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
    expected_key,
    expected_value,
    expected_right_bracket,
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
        const ParserImpl = @This();
        const Stream = std.io.PeekStream(.{ .Static = 2 }, Reader);

        allocator: std.mem.Allocator,

        stream: Stream,
        strings: std.ArrayListUnmanaged(u8) = .{},

        output: common.Toml,
        current_table: *common.Value.Table,

        fn init(allocator: std.mem.Allocator, reader: Reader) !ParserImpl {
            return ParserImpl{
                .allocator = allocator,
                .stream = Stream.init(reader),
                .output = common.Toml{ .allocator = allocator },
                .current_table = undefined,
            };
        }

        fn deinit(parser: *ParserImpl) void {
            parser.strings.deinit(parser.allocator);
            parser.* = undefined;
        }

        fn parse(parser: *ParserImpl) !common.Toml {
            parser.current_table = &parser.output.root;
            errdefer parser.output.deinit();

            while (true) {
                try parser.skipWhitespace();

                if (try parser.match('[')) {
                    try parser.skipWhitespace();

                    const key_segments = (try parser.parseKey()) orelse return error.expected_key;
                    defer parser.allocator.free(key_segments);

                    try parser.skipWhitespace();

                    try parser.consume(']', "Expected right bracket after table key.", error.expected_right_bracket);

                    try parser.skipWhitespace();

                    var current_table = &parser.output.root;
                    for (key_segments[0 .. key_segments.len - 1]) |key_bounds| {
                        const key = parser.getString(key_bounds);
                        const gop = try current_table.getOrPut(parser.output.allocator, key);
                        if (gop.found_existing) {
                            if (gop.value_ptr.* == .table) {
                                current_table = &gop.value_ptr.*.table;
                            } else {
                                return error.duplicate_key;
                            }
                        } else {
                            gop.key_ptr.* = try parser.output.allocator.dupe(u8, key);
                            gop.value_ptr.* = .{ .table = .{} };
                            current_table = &gop.value_ptr.*.table;
                        }
                    }

                    const key_bounds = key_segments[key_segments.len - 1];
                    const key = parser.getString(key_bounds);
                    const gop = try current_table.getOrPut(parser.output.allocator, key);
                    if (gop.found_existing) {
                        return error.duplicate_key;
                    } else {
                        gop.key_ptr.* = try parser.output.allocator.dupe(u8, key);
                        gop.value_ptr.* = .{ .table = .{} };
                        current_table = &gop.value_ptr.*.table;
                    }

                    parser.current_table = current_table;
                }

                try parser.matchKeyValuePair();
                const found_newline = try parser.matchNewLine();

                const c = try parser.readByte();
                if (c) |b| {
                    if (!found_newline) return error.expected_newline else try parser.stream.putBackByte(b);
                } else break;
            }

            return parser.output;
        }

        fn readByte(parser: *ParserImpl) !?u8 {
            return parser.stream.reader().readByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return error.io_error,
            };
        }

        fn checkFn(parser: *ParserImpl, callback: fn (u8) bool) !bool {
            if (try parser.readByte()) |byte| {
                try parser.stream.putBackByte(byte);
                return callback(byte);
            }
            return false;
        }

        fn match(parser: *ParserImpl, char: u8) !bool {
            if (try parser.readByte()) |byte| {
                if (char == byte)
                    return true;

                try parser.stream.putBackByte(byte);
            }

            return false;
        }

        fn matchFn(parser: *ParserImpl, callback: fn (u8) bool) !bool {
            if (try parser.readByte()) |byte| {
                if (callback(byte))
                    return true;

                try parser.stream.putBackByte(byte);
            }

            return false;
        }

        fn consume(parser: *ParserImpl, char: u8, message: []const u8, err: DecodeError) !void {
            if (try parser.readByte()) |byte| if (char == byte) return;

            std.debug.print("{s}\n", .{message});
            return err;
        }

        fn matchNewLine(parser: *ParserImpl) !bool {
            if (try parser.match('\n')) {
                return true;
            } else if (try parser.match('\r')) {
                try parser.consume('\n', "Carriage return without matching line feed.", error.invalid_newline);
                return true;
            }
            return false;
        }

        fn ensureNotEof(parser: *ParserImpl) !void {
            if (try parser.readByte()) |byte| {
                try parser.stream.putBackByte(byte);
            } else {
                return error.unexpected_eof;
            }
        }

        fn matchKeyValuePair(parser: *ParserImpl) !void {
            const maybe_key_segments = try parser.parseKey();
            const key_segments = maybe_key_segments orelse return;
            defer parser.allocator.free(key_segments);

            try parser.consume('=', "Expected equals after key.", error.expected_equals);
            try parser.skipWhitespace();

            var value: common.Value = undefined;
            {
                try parser.ensureNotEof();

                if (try parser.match('"')) {
                    const bounds = try parser.tokenizeString(.basic, .allow_multi);
                    value = .{ .string = parser.getString(bounds) };
                } else if (try parser.match('\'')) {
                    const bounds = try parser.tokenizeString(.literal, .allow_multi);
                    value = .{ .string = parser.getString(bounds) };
                } else else_prong: {
                    if (try parser.checkFn(std.ascii.isDigit)) {
                        value = try parser.tokenizeNumber(.positive);
                        break :else_prong;
                    }

                    if (try parser.match('-')) {
                        value = try parser.tokenizeNumber(.negative);
                        break :else_prong;
                    }

                    if (try parser.match('+')) {
                        value = try parser.tokenizeNumber(.positive);
                        break :else_prong;
                    }

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

            var current_table = parser.current_table;
            for (key_segments[0 .. key_segments.len - 1]) |key_bounds| {
                const key = parser.getString(key_bounds);
                const gop = try current_table.getOrPut(parser.output.allocator, key);
                if (gop.found_existing) {
                    if (gop.value_ptr.* == .table) {
                        current_table = &gop.value_ptr.*.table;
                    } else {
                        return error.duplicate_key;
                    }
                } else {
                    gop.key_ptr.* = try parser.output.allocator.dupe(u8, key);
                    gop.value_ptr.* = .{ .table = .{} };
                    current_table = &gop.value_ptr.*.table;
                }
            }

            const key_bounds = key_segments[key_segments.len - 1];
            const key = parser.getString(key_bounds);
            const gop = try current_table.getOrPut(parser.output.allocator, key);
            if (gop.found_existing) {
                return error.duplicate_key;
            } else {
                gop.key_ptr.* = try parser.output.allocator.dupe(u8, key);
                if (value == .string) {
                    value.string = try parser.output.allocator.dupe(u8, value.string);
                }
                gop.value_ptr.* = value;
            }

            try parser.skipWhitespace();
        }

        fn parseKey(parser: *ParserImpl) !?[]const StringBounds {
            var segments = std.ArrayList(StringBounds).init(parser.allocator);
            errdefer segments.deinit();

            while (true) {
                if (try parser.match('"')) {
                    const bounds = try parser.tokenizeString(.basic, .forbid_multi);
                    try segments.append(bounds);
                } else if (try parser.match('\'')) {
                    const bounds = try parser.tokenizeString(.literal, .forbid_multi);
                    try segments.append(bounds);
                } else if (try parser.checkFn(isBareKeyChar)) {
                    const bounds = try parser.tokenizeBareKey();
                    try segments.append(bounds);
                } else {
                    return null;
                }

                try parser.skipWhitespace();

                if (try parser.match('.')) {
                    try parser.skipWhitespace();
                } else {
                    break;
                }
            }

            return segments.toOwnedSlice();
        }

        fn tokenizeBareKey(parser: *ParserImpl) !StringBounds {
            const start = parser.strings.items.len;

            while (try parser.checkFn(isBareKeyChar)) {
                const c = try parser.readByte();
                try parser.strings.append(parser.allocator, c.?);
            }

            const len = parser.strings.items.len - start;
            if (len == 0) return error.zero_length_bare_key;
            return StringBounds{ .start = start, .len = len };
        }

        const AllowMulti = enum { forbid_multi, allow_multi };
        const StringKind = enum { basic, literal };

        fn tokenizeString(
            parser: *ParserImpl,
            kind: StringKind,
            allow_multi: AllowMulti,
        ) !StringBounds {
            const start = parser.strings.items.len;

            const delimiter: u8 = switch (kind) {
                .basic => '"',
                .literal => '\'',
            };
            const is_multi = try parser.matchMulti(delimiter);

            if (is_multi and allow_multi == .forbid_multi)
                return error.unexpected_multi_line_string;

            if (is_multi) {
                // skip new line immediately after """ or '''
                _ = try parser.matchNewLine();
            }

            while (true) {
                try parser.ensureNotEof();

                if (is_multi) {
                    if (try parser.match(delimiter)) {
                        if (try parser.matchMulti(delimiter))
                            break;
                        try parser.strings.append(parser.allocator, delimiter);
                        continue;
                    }
                } else {
                    if (try parser.match(delimiter)) break;
                }

                if (is_multi and try parser.matchFn(isDisallowedInMultiStrings))
                    return error.invalid_control_in_basic_string;
                if (!is_multi and try parser.match('\n'))
                    return error.invalid_newline_in_basic_string;
                if (!is_multi and try parser.matchFn(isDisallowedInSingleStrings))
                    return error.invalid_control_in_basic_string;

                if (kind == .basic and try parser.match('\\')) {
                    var c = (try parser.readByte()) orelse return error.unexpected_eof;
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
                                try parser.consume('\n', "Carriage return without matching line feed.", error.invalid_newline);
                                found_the_newline = true;
                            }

                            while (true) {
                                c = (try parser.readByte()) orelse return error.unexpected_eof;
                                switch (c) {
                                    ' ', '\t' => {},
                                    '\n' => found_the_newline = true,
                                    '\r' => {
                                        try parser.consume('\n', "Carriage return without matching line feed.", error.invalid_newline);
                                        found_the_newline = true;
                                    },
                                    else => {
                                        if (!found_the_newline) {
                                            std.log.err("Found '{c}' before finding the newline while parsing line ending backslash.", .{c});
                                            return error.invalid_escape_sequence;
                                        }

                                        try parser.stream.putBackByte(c);
                                        break;
                                    },
                                }
                            }
                        },
                        else => return error.invalid_escape_sequence,
                    }
                } else {
                    const byte = try parser.readByte();
                    try parser.strings.append(parser.allocator, byte.?);
                }
            }

            return StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn matchMulti(parser: *ParserImpl, delimiter: u8) !bool {
            if (try parser.readByte()) |c| {
                if (c == delimiter) {
                    if (try parser.readByte()) |c2| {
                        if (c2 == delimiter)
                            return true;

                        try parser.stream.putBackByte(c2);
                    }
                }
                try parser.stream.putBackByte(c);
            }

            return false;
        }

        fn tokenizeUnicodeSequence(parser: *ParserImpl, comptime len: u8) !void {
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

        const Sign = enum { positive, negative };

        fn tokenizeNumber(parser: *ParserImpl, sign: Sign) !common.Value {
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

            if (sign == .negative) {
                number = -number;
            }

            return common.Value{ .integer = number };
        }

        fn skipComment(parser: *ParserImpl) !void {
            while (true) {
                if (try parser.matchNewLine()) {
                    try parser.stream.putBackByte('\n');
                    break;
                } else {
                    const c = try parser.readByte();
                    if (c == null) break;
                }
            }
        }

        fn skipWhitespace(parser: *ParserImpl) !void {
            while (try parser.matchFn(isWhitespace)) {}
            if (try parser.match('#')) try parser.skipComment();
        }

        fn getString(parser: *ParserImpl, bounds: StringBounds) []const u8 {
            std.debug.assert(parser.strings.items.len >= bounds.start + bounds.len);
            return parser.strings.items[bounds.start .. bounds.start + bounds.len];
        }
    };
}

const StringBounds = struct {
    start: usize,
    len: usize,
};

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlNum(c) or c == '_' or c == '-';
}
fn hexValue(c: u8) u8 {
    return if (std.ascii.isDigit(c)) c - '0' else std.ascii.toLower(c) - 'a' + 10;
}

fn digitValue(c: u8) u8 {
    return c - '0';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
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

fn isDisallowedInMultiStrings(c: u8) bool {
    return std.ascii.isCntrl(c) and c != '\t' and c != '\n' and c != '\r';
}

fn isDisallowedInSingleStrings(c: u8) bool {
    return std.ascii.isCntrl(c) and c != '\t';
}
