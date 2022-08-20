const std = @import("std");
const common = @import("toml_common.zig");

pub fn decode(allocator: std.mem.Allocator, reader: anytype) !common.Toml {
    var parser = try Parser(@TypeOf(reader)).init(allocator, reader);
    defer parser.deinit();

    const result = try parser.parse();

    return result;
}

fn Parser(comptime Reader: type) type {
    return struct {
        const lookahead = 1;
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
            if (parser.current.kind == .err) @panic("err token found on advance call");
        }

        fn consume(parser: *@This(), kind: TokenKind, message: []const u8) !void {
            if (parser.current.kind == kind) {
                try parser.advance();
                return;
            }

            std.log.err("{s}", .{message});
            std.debug.panic("unexpected token found on consume call\nexpected {any}, found {any}\n[{s}]", .{ kind, parser.current.kind, message });
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
            } else return error.parse_error;

            try parser.output.root.put(parser.output.allocator, key, value);
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
                    const bounds = try parser.tokenizeBasicString();
                    token.kind = .basic_string;
                    token.val = .{ .string = bounds };
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
                else => {
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
                    } else {
                        std.log.err("FOUND UNEXPECTED CHARACTER: [{c}]", .{c});
                    }
                },
            }

            return token;
        }

        fn readByte(parser: *@This()) !?u8 {
            return parser.stream.reader().readByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
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
            const scalar = try std.fmt.parseInt(u21, &digits, 16);
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = try std.unicode.utf8Encode(scalar, &utf8_buf);
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
    @"true",
    @"false",
    lbracket,
    rbracket,
    equals,
    eof,
    err,
};

test "basic" {
    var stream = std.io.fixedBufferStream(
        \\la_bufa =true
        \\#esta pasando una crisis perrotini
        \\la_yusa= false
    );

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(true, toml.get("la_bufa").?.boolean);
    try std.testing.expectEqual(false, toml.get("la_yusa").?.boolean);
}

test "values" {
    var stream = std.io.fixedBufferStream(
        \\basic-string = "take me to your leader"
        \\basic-string-escape = "\" \\ \b \t \n \f \r"
        \\basic-string-unicode = "ñ \u0123 \U0001f415"
        // \\boolean-true = true
        // \\boolean-false = false
        // \\integer = 123
        // \\negative-integer = -123
        // \\float = 1.0
        // \\negative-float = -1.0
    );

    var toml = try decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "take me to your leader", toml.get("basic-string").?.string);
    try std.testing.expectEqualSlices(u8, "\" \\ \x08 \t \n \x0C \r", toml.get("basic-string-escape").?.string);
    try std.testing.expectEqualSlices(u8, "ñ \u{123} \u{1f415}", toml.get("basic-string-unicode").?.string);
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
