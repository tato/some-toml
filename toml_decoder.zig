const std = @import("std");
const common = @import("toml_common.zig");

pub fn parse(allocator: std.mem.Allocator, reader: anytype) DecodeError!common.Toml {
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
    overflow,
};

fn Parser(comptime Reader: type) type {
    return struct {
        const ParserImpl = @This();
        const Stream = std.io.PeekStream(.{ .Static = 2 }, Reader);
        const stack_fallback_size = 1 << 10;
        const StackFallback = std.heap.StackFallbackAllocator(stack_fallback_size);

        allocator: std.mem.Allocator,
        stack_fallback: StackFallback,

        stream: Stream,

        output: common.Toml,
        current_table: *common.Value.Table,

        fn init(allocator: std.mem.Allocator, reader: Reader) !ParserImpl {
            return ParserImpl{
                .allocator = allocator,
                .stack_fallback = std.heap.stackFallback(stack_fallback_size, allocator),
                .stream = Stream.init(reader),
                .output = common.Toml{ .allocator = allocator },
                .current_table = undefined,
            };
        }

        fn deinit(parser: *ParserImpl) void {
            parser.* = undefined;
        }

        fn parse(parser: *ParserImpl) !common.Toml {
            parser.current_table = &parser.output.root;
            errdefer parser.output.deinit();

            while (!(try parser.isAtEof())) {
                try parser.skipWhitespace();
                if (try parser.matchNewLine()) continue;

                if (try parser.match('[')) {
                    if (try parser.match('[')) {
                        const sfa = parser.stack_fallback.get();

                        try parser.skipWhitespace();

                        var current_table = &parser.output.root;

                        while (true) {
                            var out = std.ArrayList(u8).init(sfa);
                            defer out.deinit();

                            try parser.parseKeySegment(&out);
                            try parser.skipWhitespace();
                            const has_more_segments = try parser.match('.');
                            if (has_more_segments) try parser.skipWhitespace();

                            const gop = try current_table.getOrPut(parser.output.allocator, out.items);
                            if (has_more_segments) {
                                if (!gop.found_existing) {
                                    gop.key_ptr.* = try parser.output.allocator.dupe(u8, out.items);
                                    gop.value_ptr.* = .{ .table = .{} };
                                    current_table = &gop.value_ptr.*.table;
                                } else if (gop.value_ptr.* == .table) {
                                    current_table = &gop.value_ptr.*.table;
                                } else {
                                    return error.duplicate_key;
                                }
                            } else {
                                if (!gop.found_existing) {
                                    gop.key_ptr.* = try parser.output.allocator.dupe(u8, out.items);
                                    gop.value_ptr.* = .{ .array = .{} };
                                    try gop.value_ptr.array.append(parser.output.allocator, .{ .table = .{} });
                                    current_table = &gop.value_ptr.array.items[gop.value_ptr.array.items.len - 1].table;
                                } else if (gop.value_ptr.* == .array) {
                                    try gop.value_ptr.array.append(parser.output.allocator, .{ .table = .{} });
                                    current_table = &gop.value_ptr.array.items[gop.value_ptr.array.items.len - 1].table;
                                } else {
                                    return error.duplicate_key;
                                }
                                break;
                            }
                        }

                        parser.current_table = current_table;

                        try parser.skipWhitespace();

                        try parser.consume(']', "Expected ']]' after array of tables key.", error.expected_right_bracket);
                        try parser.consume(']', "Expected ']]' after array of tables key.", error.expected_right_bracket);

                        try parser.skipWhitespace();
                        try parser.consumeNewLineOrEof();
                    } else {
                        const sfa = parser.stack_fallback.get();

                        try parser.skipWhitespace();

                        var current_table = &parser.output.root;

                        while (true) {
                            var out = std.ArrayList(u8).init(sfa);
                            defer out.deinit();

                            try parser.parseKeySegment(&out);
                            try parser.skipWhitespace();
                            const has_more_segments = try parser.match('.');
                            if (has_more_segments) try parser.skipWhitespace();

                            const gop = try current_table.getOrPut(parser.output.allocator, out.items);
                            if (!gop.found_existing) {
                                gop.key_ptr.* = try parser.output.allocator.dupe(u8, out.items);
                                gop.value_ptr.* = .{ .table = .{} };
                                current_table = &gop.value_ptr.*.table;
                            } else if (gop.value_ptr.* == .table) {
                                current_table = &gop.value_ptr.*.table;
                            } else {
                                return error.duplicate_key;
                            }

                            if (!has_more_segments) break;
                        }

                        parser.current_table = current_table;

                        try parser.skipWhitespace();

                        try parser.consume(']', "Expected ']' after table key.", error.expected_right_bracket);

                        try parser.skipWhitespace();
                        try parser.consumeNewLineOrEof();
                    }
                } else {
                    try parser.matchKeyValuePair();
                    try parser.consumeNewLineOrEof();
                }
            }

            return parser.output;
        }

        fn readByte(parser: *ParserImpl) !?u8 {
            return parser.stream.reader().readByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return error.io_error,
            };
        }

        fn isAtEof(parser: *ParserImpl) !bool {
            if (try parser.readByte()) |byte| {
                try parser.stream.putBackByte(byte);
                return false;
            }
            return true;
        }

        fn checkFn(parser: *ParserImpl, comptime callback: fn (u8) bool) !bool {
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

        fn matchFn(parser: *ParserImpl, comptime callback: fn (u8) bool) !bool {
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

        fn consumeNewLineOrEof(parser: *ParserImpl) !void {
            if (try parser.isAtEof()) {
                return;
            } else if (try parser.match('\n')) {
                return;
            } else if (try parser.match('\r')) {
                try parser.consume('\n', "Carriage return without matching line feed.", error.invalid_newline);
                return;
            }

            std.debug.print("Expected new line.\n", .{});
            return error.expected_newline;
        }

        fn ensureNotEof(parser: *ParserImpl) !void {
            if (try parser.readByte()) |byte| {
                try parser.stream.putBackByte(byte);
            } else {
                return error.unexpected_eof;
            }
        }

        fn matchKeyValuePair(parser: *ParserImpl) !void {
            if (try parser.isAtEof()) return;

            var current_table = parser.current_table;

            const value_ptr: *common.Value = while (true) {
                var out = std.ArrayList(u8).init(parser.stack_fallback.get());
                defer out.deinit();

                try parser.parseKeySegment(&out);
                try parser.skipWhitespace();
                const has_more_segments = try parser.match('.');
                if (has_more_segments) try parser.skipWhitespace();

                const gop = try current_table.getOrPut(parser.output.allocator, out.items);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try parser.output.allocator.dupe(u8, out.items);
                    if (has_more_segments) {
                        gop.value_ptr.* = .{ .table = .{} };
                        current_table = &gop.value_ptr.*.table;
                    } else {
                        break gop.value_ptr;
                    }
                } else if (has_more_segments and gop.value_ptr.* == .table) {
                    current_table = &gop.value_ptr.*.table;
                } else {
                    return error.duplicate_key;
                }
            } else unreachable;

            try parser.consume('=', "Expected equals after key.", error.expected_equals);
            try parser.skipWhitespace();

            try parser.parseValue(value_ptr);

            try parser.skipWhitespace();
        }

        fn parseKeySegment(parser: *ParserImpl, out: *std.ArrayList(u8)) !void {
            if (try parser.match('"')) {
                try parser.tokenizeString(.basic, .forbid_multi, out);
            } else if (try parser.match('\'')) {
                try parser.tokenizeString(.literal, .forbid_multi, out);
            } else if (try parser.checkFn(isBareKeyChar)) {
                try parser.tokenizeBareKey(out);
            } else {
                return error.expected_key;
            }
        }

        fn parseValue(parser: *ParserImpl, value_ptr: *common.Value) DecodeError!void {
            const sfa = parser.stack_fallback.get();
            try parser.ensureNotEof();

            if (try parser.match('"')) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();
                try parser.tokenizeString(.basic, .allow_multi, &out);
                value_ptr.* = .{ .string = try parser.output.allocator.dupe(u8, out.items) };
            } else if (try parser.match('\'')) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();
                try parser.tokenizeString(.literal, .allow_multi, &out);
                value_ptr.* = .{ .string = try parser.output.allocator.dupe(u8, out.items) };
            } else if (try parser.match('[')) {
                value_ptr.* = .{ .array = .{} };
                while (true) {
                    try parser.skipWhitespace();
                    if (try parser.matchNewLine()) continue;

                    try value_ptr.array.append(parser.output.allocator, undefined);
                    try parser.parseValue(&value_ptr.array.items[value_ptr.array.items.len - 1]);

                    try parser.skipWhitespace();
                    while (try parser.matchNewLine()) try parser.skipWhitespace();

                    const match_comma = try parser.match(',');

                    try parser.skipWhitespace();
                    while (try parser.matchNewLine()) try parser.skipWhitespace();

                    const match_right_bracket = try parser.match(']');

                    if (match_right_bracket) {
                        break;
                    } else if (!match_comma) {
                        std.debug.print("Expected ']' after list value.\n", .{});
                        return error.expected_right_bracket;
                    }
                }
            } else if (try parser.match('{')) {
                value_ptr.* = .{ .table = .{} };

                const previous_current_table = parser.current_table;
                parser.current_table = &value_ptr.*.table;
                defer parser.current_table = previous_current_table;

                while (true) {
                    try parser.skipWhitespace();
                    if (try parser.matchNewLine()) continue;

                    try parser.matchKeyValuePair();

                    try parser.skipWhitespace();
                    while (try parser.matchNewLine()) try parser.skipWhitespace();

                    const match_comma = try parser.match(',');

                    try parser.skipWhitespace();
                    while (try parser.matchNewLine()) try parser.skipWhitespace();

                    const match_right_bracket = try parser.match('}');

                    if (match_right_bracket) {
                        break;
                    } else if (!match_comma) {
                        std.debug.print("Expected '}}' after inline table value.\n", .{});
                        return error.expected_right_bracket;
                    }
                }
            } else else_prong: {
                if (try parser.checkFn(std.ascii.isDigit)) {
                    var buf = std.ArrayList(u8).init(sfa);
                    defer buf.deinit();

                    value_ptr.* = try parser.tokenizeNumber(&buf);
                    break :else_prong;
                }

                if (try parser.match('-')) {
                    var buf = std.ArrayList(u8).init(sfa);
                    defer buf.deinit();
                    try buf.append('-');

                    value_ptr.* = try parser.tokenizeNumber(&buf);
                    break :else_prong;
                }

                if (try parser.match('+')) {
                    var buf = std.ArrayList(u8).init(sfa);
                    defer buf.deinit();
                    try buf.append('+');

                    value_ptr.* = try parser.tokenizeNumber(&buf);
                    break :else_prong;
                }

                var string = std.ArrayList(u8).init(sfa);
                parser.tokenizeBareKey(&string) catch |e| switch (e) {
                    error.zero_length_bare_key => return error.expected_value,
                    else => return e,
                };
                if (std.mem.eql(u8, "true", string.items)) {
                    value_ptr.* = .{ .boolean = true };
                } else if (std.mem.eql(u8, "false", string.items)) {
                    value_ptr.* = .{ .boolean = false };
                } else if (std.mem.eql(u8, "inf", string.items)) {
                    value_ptr.* = .{ .float = std.math.inf_f64 };
                } else if (std.mem.eql(u8, "nan", string.items)) {
                    value_ptr.* = .{ .float = std.math.nan_f64 };
                } else {
                    return error.unexpected_bare_key;
                }
                string.deinit();
            }
        }

        fn tokenizeBareKey(parser: *ParserImpl, out: *std.ArrayList(u8)) !void {
            errdefer out.deinit();

            while (try parser.checkFn(isBareKeyChar)) {
                const c = try parser.readByte();
                try out.append(c.?);
            }

            if (out.items.len == 0) return error.zero_length_bare_key;
        }

        const AllowMulti = enum { forbid_multi, allow_multi };
        const StringKind = enum { basic, literal };

        fn tokenizeString(
            parser: *ParserImpl,
            kind: StringKind,
            allow_multi: AllowMulti,
            out: *std.ArrayList(u8),
        ) !void {
            errdefer out.deinit();

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
                        try out.append(delimiter);
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
                        '"', '\\' => try out.append(c),
                        'b' => try out.append(std.ascii.control_code.BS),
                        't' => try out.append('\t'),
                        'n' => try out.append('\n'),
                        'f' => try out.append(std.ascii.control_code.FF),
                        'r' => try out.append('\r'),
                        'u' => try parser.tokenizeUnicodeSequence(4, out),
                        'U' => try parser.tokenizeUnicodeSequence(8, out),
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
                    try out.append(byte.?);
                }
            }
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

        fn tokenizeUnicodeSequence(parser: *ParserImpl, comptime len: u8, out: *std.ArrayList(u8)) !void {
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
            try out.appendSlice(utf8_buf[0..utf8_len]);
        }

        fn tokenizeNumber(parser: *ParserImpl, buf: *std.ArrayList(u8)) !common.Value {
            if (try parser.match('i')) {
                try parser.consume('n', "Unexpected char 'i'.", error.unexpected_character);
                try parser.consume('f', "Unexpected char 'f'.", error.unexpected_character);

                const val = if (buf.items.len >= 1 and buf.items[0] == '-')
                    -std.math.inf_f64
                else
                    std.math.inf_f64;
                return .{ .float = val };
            }

            if (try parser.match('n')) {
                try parser.consume('a', "Unexpected char 'n'.", error.unexpected_character);
                try parser.consume('n', "Unexpected char 'n'.", error.unexpected_character);
                return .{ .float = std.math.nan_f64 };
            }

            const radix: u8 = base: {
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

            try parser.tokenizeInteger(buf, radix);
            if (radix != 10) {
                const integer = std.fmt.parseInt(i64, buf.items, radix) catch |e| switch (e) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => return error.overflow,
                };
                return common.Value{ .integer = integer };
            }

            var is_float = false;

            if (try parser.match('.')) {
                is_float = true;

                try buf.append('.');
                try parser.tokenizeInteger(buf, 10);
            }

            if ((try parser.match('e')) or (try parser.match('E'))) {
                is_float = true;

                try buf.append('e');

                if (try parser.match('+')) {
                    try buf.append('+');
                } else if (try parser.match('-')) {
                    try buf.append('-');
                }

                try parser.tokenizeInteger(buf, 10);
            }

            if (is_float) {
                const float = std.fmt.parseFloat(f64, buf.items) catch |e| switch (e) {
                    error.InvalidCharacter => unreachable,
                };
                return common.Value{ .float = float };
            } else {
                const integer = std.fmt.parseInt(i64, buf.items, radix) catch |e| switch (e) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => return error.overflow,
                };
                return common.Value{ .integer = integer };
            }
        }

        fn tokenizeInteger(parser: *ParserImpl, buf: *std.ArrayList(u8), base: i64) !void {
            const valid_fn = &switch (base) {
                16 => isHexDigit,
                10 => std.ascii.isDigit,
                8 => isOctalDigit,
                2 => isBinDigit,
                else => unreachable,
            };

            var c = (try parser.readByte()) orelse return error.unexpected_eof;
            if (!valid_fn(c)) return error.unexpected_character;
            while (true) {
                if (valid_fn(c)) {
                    try buf.append(c);
                } else if (c != '_') {
                    try parser.stream.putBackByte(c);
                    break;
                }
                c = (try parser.readByte()) orelse break;
            }
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
    };
}

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
