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
    unexpected_eof,
    unexpected_character,
    unexpected_token,
    expected_value,
    invalid_newline_in_basic_string,
    invalid_control_in_basic_string,
    invalid_escape_sequence,
    invalid_char_in_unicode_escape_sequence,
    invalid_unicode_scalar_in_escape_sequence,
    repeated_key,
};

fn Parser(comptime Reader: type) type {
    return struct {
        const lookahead = 2;
        const Stream = std.io.PeekStream(.{ .Static = lookahead }, Reader);

        allocator: std.mem.Allocator,
        previous: Token = undefined,
        current: Token = undefined,

        stream: Stream,
        strings: std.ArrayListUnmanaged(u8) = .{},

        output: common.Toml,

        fn init(allocator: std.mem.Allocator, reader: Reader) !@This() {
            const output = common.Toml{ .allocator = allocator };
            const peekable = std.io.peekStream(lookahead, reader);
            var parser = @This(){ .allocator = allocator, .stream = peekable, .output = output };
            try parser.advance();
            return parser;
        }

        fn deinit(parser: *@This()) void {
            parser.strings.deinit(parser.allocator);
            parser.* = undefined;
        }

        fn parse(parser: *@This()) !common.Toml {
            errdefer parser.output.deinit();

            while (true) {
                if (try parser.match(.bare_key)) {
                    try parser.parseKvPair();
                } else if (try parser.match(.basic_string)) {
                    try parser.parseKvPair();
                } else if (try parser.match(.literal_string)) {
                    try parser.parseKvPair();
                }

                if (try parser.match(.newline)) {} else {
                    break;
                }
            }

            try parser.consume(.eof, "Expected eof.");

            return parser.output;
        }

        fn check(parser: *@This(), kind: TokenKind) bool {
            return parser.current.kind == kind;
        }

        fn match(parser: *@This(), kind: TokenKind) !bool {
            if (!parser.check(kind)) return false;
            try parser.advance();
            return true;
        }

        fn advance(parser: *@This()) !void {
            parser.previous = parser.current;
            parser.current = try parser.nextToken();
            if (parser.current.kind == .err) return error.unexpected_token;
        }

        fn consume(parser: *@This(), kind: TokenKind, message: []const u8) !void {
            if (parser.current.kind == kind) {
                try parser.advance();
                return;
            }

            std.log.debug("{s}", .{message});
            return error.unexpected_token;
        }

        fn parseKvPair(parser: *@This()) !void {
            const key = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string));
            errdefer parser.output.allocator.free(key);

            try parser.consume(.equals, "Expected '=' after key.");

            var value: common.Value = undefined;
            if (try parser.match(.@"true")) {
                value = .{ .boolean = true };
            } else if (try parser.match(.@"false")) {
                value = .{ .boolean = false };
            } else if (try parser.match(.basic_string)) {
                value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string)) };
            } else if (try parser.match(.multi_line_basic_string)) {
                value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string)) };
            } else if (try parser.match(.literal_string)) {
                value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string)) };
            } else if (try parser.match(.multi_line_literal_string)) {
                value = .{ .string = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string)) };
            } else return error.expected_value;

            errdefer value.deinit(parser.output.allocator);

            const gop = try parser.output.root.getOrPut(parser.output.allocator, key);
            if (gop.found_existing) {
                return error.repeated_key;
            } else {
                gop.value_ptr.* = value;
            }
        }

        fn nextToken(parser: *@This()) !Token {
            var token = Token{ .kind = .err };

            try parser.skipWhitespace();

            const c = (try parser.readByte()) orelse {
                token.kind = .eof;
                return token;
            };

            switch (c) {
                '#' => {
                    try parser.skipComment();
                    token.kind = .newline;
                },
                '[' => token.kind = .lbracket,
                ']' => token.kind = .rbracket,
                '=' => token.kind = .equals,
                '"' => {
                    const next = try parser.readByte();
                    const nextnext = try parser.readByte();
                    if (next != null and next.? == '"' and nextnext != null and nextnext.? == '"') {
                        const bounds = try parser.tokenizeMultiLineBasicString();
                        token.kind = .multi_line_basic_string;
                        token.val = .{ .string = bounds };
                    } else {
                        if (nextnext) |nn| try parser.stream.putBackByte(nn);
                        if (next) |n| try parser.stream.putBackByte(n);

                        const bounds = try parser.tokenizeBasicString();
                        token.kind = .basic_string;
                        token.val = .{ .string = bounds };
                    }
                },
                '\'' => {
                    const next = try parser.readByte();
                    const nextnext = try parser.readByte();
                    if (next != null and next.? == '\'' and nextnext != null and nextnext.? == '\'') {
                        const bounds = try parser.tokenizeMultiLineLiteralString();
                        token.kind = .multi_line_literal_string;
                        token.val = .{ .string = bounds };
                    } else {
                        if (nextnext) |nn| try parser.stream.putBackByte(nn);
                        if (next) |n| try parser.stream.putBackByte(n);

                        const bounds = try parser.tokenizeLiteralString();
                        token.kind = .literal_string;
                        token.val = .{ .string = bounds };
                    }
                },
                '\n' => token.kind = .newline,
                '\r' => {
                    const nl = (try parser.readByte()) orelse {
                        std.log.err("Expected '\\n' after '\\r' but found EOF.", .{});
                        return error.unexpected_eof;
                    };
                    if (nl != '\n') {
                        std.log.err("Expected '\\n' after '\\r' but found '{c}'.", .{nl});
                        return error.unexpected_character;
                    }
                    token.kind = .newline;
                },
                else => else_prong: {
                    if (isBareKeyChar(c)) {
                        try parser.stream.putBackByte(c);

                        const bounds = try parser.tokenizeBareKey();
                        const string = parser.getString(bounds);

                        token.val = .{ .string = bounds };
                        token.kind = .bare_key;

                        if (std.mem.eql(u8, "true", string)) {
                            token.kind = .@"true";
                        } else if (std.mem.eql(u8, "false", string)) {
                            token.kind = .@"false";
                        }
                        break :else_prong;
                    }

                    std.log.err("FOUND UNEXPECTED CHARACTER: [{c}]", .{c});
                },
            }

            return token;
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

        fn tokenizeBareKey(parser: *@This()) !Token.StringBounds {
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

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeBasicString(parser: *@This()) !Token.StringBounds {
            const start = parser.strings.items.len;

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (c == '"') break;

                if (c == '\n') return error.invalid_newline_in_basic_string;
                if (std.ascii.isCntrl(c) and c != '\t') return error.invalid_control_in_basic_string;

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
                        else => return error.invalid_escape_sequence,
                    }
                } else {
                    try parser.strings.append(parser.allocator, c);
                }
            }

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeMultiLineBasicString(parser: *@This()) !Token.StringBounds {
            const start = parser.strings.items.len;

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

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (std.ascii.isCntrl(c) and c != '\t' and c != '\n' and c != '\r') return error.invalid_control_in_basic_string;

                if (c == '"') check_end: {
                    const next = (try parser.readByte()) orelse break :check_end;
                    if (next == '"') inner_check_end: {
                        const nextnext = (try parser.readByte()) orelse break :inner_check_end;
                        if (nextnext == '"') break;
                        try parser.stream.putBackByte(nextnext);
                    }
                    try parser.stream.putBackByte(next);
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

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeLiteralString(parser: *@This()) !Token.StringBounds {
            const start = parser.strings.items.len;

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (c == '\'') break;

                // TODO in_literal_string or in_single_line_string
                if (c == '\n') return error.invalid_newline_in_basic_string;
                if (std.ascii.isCntrl(c) and c != '\t') return error.invalid_control_in_basic_string;

                try parser.strings.append(parser.allocator, c);
            }

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
        }

        fn tokenizeMultiLineLiteralString(parser: *@This()) !Token.StringBounds {
            const start = parser.strings.items.len;

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

            while (true) {
                var c = (try parser.readByte()) orelse return error.unexpected_eof;

                if (std.ascii.isCntrl(c) and c != '\t' and c != '\n' and c != '\r') return error.invalid_control_in_basic_string;

                if (c == '\'') check_end: {
                    const next = (try parser.readByte()) orelse break :check_end;
                    if (next == '\'') inner_check_end: {
                        const nextnext = (try parser.readByte()) orelse break :inner_check_end;
                        if (nextnext == '\'') break;
                        try parser.stream.putBackByte(nextnext);
                    }
                    try parser.stream.putBackByte(next);
                }

                try parser.strings.append(parser.allocator, c);
            }

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
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

        fn skipComment(parser: *@This()) !void {
            while (true) {
                const c = try parser.readByte();
                if (c == null or c.? == 0x0A) break;
            }
        }

        fn skipWhitespace(parser: *@This()) !void {
            var c = (try parser.readByte()) orelse return;
            while (c == ' ' or c == '\t') : (c = (try parser.readByte()) orelse return) {}
            try parser.stream.putBackByte(c);
        }

        fn getString(parser: *@This(), bounds: Token.StringBounds) []const u8 {
            std.debug.assert(parser.strings.items.len >= bounds.start + bounds.len);
            return parser.strings.items[bounds.start .. bounds.start + bounds.len];
        }
    };
}

const Token = struct {
    kind: TokenKind,
    val: Value = .{ .none = {} },

    const Value = union(enum) {
        none: void,
        string: StringBounds,
    };

    const StringBounds = struct {
        start: usize,
        len: usize,
    };
};

const TokenKind = enum {
    newline,
    bare_key,
    basic_string,
    multi_line_basic_string,
    literal_string,
    multi_line_literal_string,
    integer,
    @"true",
    @"false",
    lbracket,
    rbracket,
    equals,
    eof,
    err,
};

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
    try std.testing.expectError(error.expected_value, err);
}

test "invalid 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 2.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.unexpected_token, err);
}

test "invalid 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 3.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.unexpected_token, err);
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
    try std.testing.expectError(error.repeated_key, err);
}

test "repeat keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 2.toml"));
    const err = decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.repeated_key, err);
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
    if (true) return error.SkipZigTest;
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
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 2.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(1_000 == toml.get("int5").?.integer);
    try std.testing.expect(5_349_221 == toml.get("int6").?.integer);
    try std.testing.expect(53_49_221 == toml.get("int7").?.integer);
    try std.testing.expect(1_2_3_4_5 == toml.get("int8").?.integer);
}

test "integers 3" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 3.toml"));
    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(0xDEADBEEF == toml.get("hex1").?.integer);
    try std.testing.expect(0xdeadbeef == toml.get("hex2").?.integer);
    try std.testing.expect(0xdead_beef == toml.get("hex3").?.integer);
    try std.testing.expect(0o01234567 == toml.get("oct1").?.integer);
    try std.testing.expect(0o755 == toml.get("oct1").?.integer);
    try std.testing.expect(0b11010110 == toml.get("bin1").?.integer);
}
