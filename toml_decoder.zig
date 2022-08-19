const std = @import("std");
const toml = @import("toml_common.zig");

pub fn decode(allocator: std.mem.Allocator, reader: anytype) !toml.Toml {
    var result = toml.Toml{ .allocator = allocator };
    errdefer result.deinit();

    const peekable = std.io.peekStream(tokenizer.lookahead, reader);
    var parser = Parser(@TypeOf(reader)).init(peekable);
    result = parser.parse();

    return result;
}

fn Parser(comptime Reader: type) type {
    return struct {
        allocator: std.mem.Allocator,
        stream: tokenizer.Stream(Reader),
        previous: Token = undefined,
        current: Token = undefined,

        fn init(allocator: std.mem.Allocator, stream: tokenizer.Stream(Reader)) @This() {
            @This(){ .allocator = allocator, .stream = stream };
        }

        fn parse(parser: *@This()) toml.Toml {
            var token = try tokenizer.nextToken(@TypeOf(reader), allocator, &peekable);
            parser.consume(.bare_key);

            while (token.kind != .eof) : (token = try tokenizer.nextToken(@TypeOf(reader), allocator, &peekable)) {
                // switch (token.kind) {
                //     .eof => unreachable,
                //     // TODO
                // }
                // if (token.val == .string) {
                //     std.debug.print(" [{s}]", .{token.val.string});
                // }
                // std.debug.print("\n", .{});
                token.deinit(allocator);
            }
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
            while (true) {
                parser.current = try tokenizer.nextToken(Reader, parser.allocator, &parser.stream);
                if (parser.current.kind != .err) break;
                @panic("Something went wrong 👹");
            }
        }

        fn consume(parser: *@This(), kind: TokenKind, message: []const u8) !void {
            if (parser.current.kind == kind) {
                try parser.advance();
                return;
            }

            std.debug.panic("Something went wrong 👹: '{s}'", .{message});
        }
    };
}

const tokenizer = struct {
    const lookahead = 1;
    fn Stream(comptime UnderlyingReader: type) type {
        return std.io.PeekStream(.{ .Static = tokenizer.lookahead }, UnderlyingReader);
    }

    fn nextToken(
        comptime Reader: type,
        allocator: std.mem.Allocator,
        peek_stream: *Stream(Reader),
    ) !Token {
        var token = Token{ .kind = .err };

        try skipWhitespace(peek_stream);

        const c = (try readByte(peek_stream)) orelse {
            token.kind = .eof;
            return token;
        };

        switch (c) {
            '#' => {
                try skipComment(peek_stream);
                token.kind = .newline;
            },
            '[' => token.kind = .lbracket,
            ']' => token.kind = .rbracket,
            '=' => token.kind = .equals,
            else => {
                if (isBareKeyChar(c)) {
                    try peek_stream.putBackByte(c);
                    token.val = .{ .string = try getBareKey(allocator, peek_stream) };
                    token.kind = .bare_key;
                    if (std.mem.eql(u8, "true", token.val.string)) {
                        token.kind = .@"true";
                    } else if (std.mem.eql(u8, "false", token.val.string)) {
                        token.kind = .@"false";
                    }
                } else {
                    std.log.err("FOUND UNEXPECTED CHARACTER: {c}", .{c});
                }
            },
        }

        return token;
    }

    fn readByte(peek_stream: anytype) !?u8 {
        return peek_stream.reader().readByte() catch |e| switch (e) {
            error.EndOfStream => return null,
            else => return e,
        };
    }

    fn isBareKeyChar(c: u8) bool {
        return std.ascii.isAlNum(c) or c == '_' or c == '-';
    }

    fn getBareKey(allocator: std.mem.Allocator, peek_stream: anytype) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        var c = (try readByte(peek_stream)).?;
        while (isBareKeyChar(c)) {
            try buf.append(c);
            if (try readByte(peek_stream)) |b| c = b else break;
        }
        return buf.toOwnedSlice();
    }

    fn skipComment(peek_stream: anytype) !void {
        while (true) {
            const c = try readByte(peek_stream);
            if (c == null or c.? == 0x0A) break;
        }
    }

    fn skipWhitespace(peek_stream: anytype) !void {
        var c = (try readByte(peek_stream)) orelse return;
        while (c == ' ' or c == '\t') : (c = (try readByte(peek_stream)) orelse return) {}
        try peek_stream.putBackByte(c);
    }
};

const Token = struct {
    kind: TokenKind,
    val: union(enum) {
        none: void,
        string: []const u8,
    } = .{ .none = {} },

    fn deinit(token: *Token, allocator: std.mem.Allocator) void {
        if (token.val == .string) allocator.free(token.val.string);
        token.* = undefined;
    }
};

const TokenKind = enum {
    newline,
    bare_key,
    @"true",
    @"false",
    lbracket,
    rbracket,
    equals,
    eof,
    err,
};

test "basic" {
    const doc =
        \\la_bufa = true
        \\#esta pasando una crisis perrotini
        \\la_yusa = true
    ;
    var fbr = std.io.fixedBufferStream(doc);
    _ = try decode(std.testing.allocator, fbr.reader());
}
