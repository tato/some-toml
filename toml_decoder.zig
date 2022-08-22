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
        const lookahead = 2;
        const Stream = std.io.PeekStream(.{ .Static = 2 }, Reader);

        allocator: std.mem.Allocator,

        stream: Stream,
        strings: std.ArrayListUnmanaged(u8) = .{},

        output: common.Toml,
        current_table: *common.Value.Table,

        fn init(allocator: std.mem.Allocator, reader: Reader) !@This() {
            const output = common.Toml{ .allocator = allocator };
            const peekable = Stream.init(reader);
            var parser = @This(){ .allocator = allocator, .stream = peekable, .output = output, .current_table = undefined };
            return parser;
        }

        fn deinit(parser: *@This()) void {
            parser.strings.deinit(parser.allocator);
            parser.* = undefined;
        }

        fn parse(parser: *@This()) !common.Toml {
            parser.current_table = &parser.output.root;
            errdefer parser.output.deinit();

            while (true) {
                try parser.skipWhitespace();

                const maybe_open_bracket = try parser.readByte();
                if (maybe_open_bracket) |open_bracket| {
                    if (open_bracket == '[') {
                        try parser.skipWhitespace();

                        const key_segments = (try parser.parseKey()) orelse return error.expected_key;
                        defer parser.allocator.free(key_segments);

                        try parser.skipWhitespace();

                        const right_bracket = (try parser.readByte()) orelse return error.unexpected_eof;
                        if (right_bracket != ']') return error.expected_right_bracket;

                        try parser.skipWhitespace();

                        var current_table = &parser.output.root;
                        for (key_segments[0 .. key_segments.len - 1]) |key_bounds| {
                            const key = try parser.output.getString(parser.getString(key_bounds));
                            const gop = try current_table.getOrPut(parser.output.allocator, key);
                            if (gop.found_existing) {
                                if (gop.value_ptr.* == .table) {
                                    current_table = &gop.value_ptr.*.table;
                                } else {
                                    return error.duplicate_key;
                                }
                            } else {
                                gop.value_ptr.* = .{ .table = .{} };
                                current_table = &gop.value_ptr.*.table;
                            }
                        }

                        const key_bounds = key_segments[key_segments.len - 1];
                        const key = try parser.output.getString(parser.getString(key_bounds));
                        const gop = try current_table.getOrPut(parser.output.allocator, key);
                        if (gop.found_existing) {
                            return error.duplicate_key;
                        } else {
                            gop.value_ptr.* = .{ .table = .{} };
                            current_table = &gop.value_ptr.*.table;
                        }

                        parser.current_table = current_table;
                    } else {
                        try parser.stream.putBackByte(open_bracket);
                    }
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

        fn matchKeyValuePair(parser: *@This()) !void {
            const maybe_key_segments = try parser.parseKey();
            const key_segments = maybe_key_segments orelse return;
            defer parser.allocator.free(key_segments);

            var value: common.Value = undefined;

            {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;
                if (c != '=') return error.expected_equals;
                try parser.skipWhitespace();
            }

            {
                const c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (c == '"') {
                    const bounds = try parser.tokenizeBasicString(.allow_multi);
                    value = .{ .string = try parser.output.getString(parser.getString(bounds)) };
                } else if (c == '\'') {
                    const bounds = try parser.tokenizeLiteralString(.allow_multi);
                    value = .{ .string = try parser.output.getString(parser.getString(bounds)) };
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

            var current_table = parser.current_table;
            for (key_segments[0 .. key_segments.len - 1]) |key_bounds| {
                const key = try parser.output.getString(parser.getString(key_bounds));
                const gop = try current_table.getOrPut(parser.output.allocator, key);
                if (gop.found_existing) {
                    if (gop.value_ptr.* == .table) {
                        current_table = &gop.value_ptr.*.table;
                    } else {
                        return error.duplicate_key;
                    }
                } else {
                    gop.value_ptr.* = .{ .table = .{} };
                    current_table = &gop.value_ptr.*.table;
                }
            }

            const key_bounds = key_segments[key_segments.len - 1];
            const key = try parser.output.getString(parser.getString(key_bounds));
            const gop = try current_table.getOrPut(parser.output.allocator, key);
            if (gop.found_existing) {
                return error.duplicate_key;
            } else {
                gop.value_ptr.* = value;
            }

            try parser.skipWhitespace();
        }

        fn parseKey(parser: *@This()) !?[]const StringBounds {
            var segments = std.ArrayList(StringBounds).init(parser.allocator);
            errdefer segments.deinit();

            while (true) {
                const c = (try parser.readByte()) orelse return null;

                if (c == '"') {
                    const bounds = try parser.tokenizeBasicString(.disallow_multi);
                    try segments.append(bounds);
                } else if (c == '\'') {
                    const bounds = try parser.tokenizeLiteralString(.disallow_multi);
                    try segments.append(bounds);
                } else if (isBareKeyChar(c)) {
                    try parser.stream.putBackByte(c);
                    const bounds = try parser.tokenizeBareKey();
                    try segments.append(bounds);
                } else {
                    try parser.stream.putBackByte(c);
                    return null;
                }

                try parser.skipWhitespace();
                const dot_char = (try parser.readByte()) orelse return error.unexpected_eof;
                if (dot_char == '.') {
                    try parser.skipWhitespace();
                } else {
                    try parser.stream.putBackByte(dot_char);
                    break;
                }
            }

            return segments.toOwnedSlice();
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
