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
            try parser.consume(.bare_key, "Expected key.");
            const key = try parser.output.allocator.dupe(u8, parser.getString(parser.previous.val.string));

            try parser.consume(.equals, "Expected '=' after key.");

            var value: common.TomlValue = undefined;
            if (try parser.match(.@"true")) {
                value = .{ .boolean = true };
            } else if (try parser.match(.@"false")) {
                value = .{ .boolean = false };
            } else return error.parse_error;

            _ = try parser.match(.newline);

            try parser.consume(.eof, "Expected eof.");

            try parser.output.root.put(parser.output.allocator, key, value);
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
                else => {
                    if (isBareKeyChar(c)) {
                        try parser.stream.putBackByte(c);

                        const bounds = try parser.getBareKey();
                        const string = parser.getString(bounds);

                        token.val = .{ .string = bounds };
                        token.kind = .bare_key;

                        if (std.mem.eql(u8, "true", string)) {
                            token.kind = .@"true";
                        } else if (std.mem.eql(u8, "false", string)) {
                            token.kind = .@"false";
                        }
                    } else {
                        std.log.err("FOUND UNEXPECTED CHARACTER: {c}", .{c});
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

        fn getBareKey(parser: *@This()) !Token.StringBounds {
            const start = parser.strings.items.len;

            var c = (try parser.readByte()).?;
            while (isBareKeyChar(c)) {
                try parser.strings.append(parser.allocator, c);
                if (try parser.readByte()) |b| c = b else break;
            }

            return Token.StringBounds{ .start = start, .len = parser.strings.items.len - start };
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
    @"true",
    @"false",
    lbracket,
    rbracket,
    equals,
    eof,
    err,
};

test "basic" {
    const source =
        \\la_bufa = true
        \\#esta pasando una crisis perrotini
        // \\la_yusa = true
    ;

    var dbg = std.io.fixedBufferStream(source);
    try debugPrintAllTokens(std.testing.allocator, dbg.reader());

    var fbr = std.io.fixedBufferStream(source);
    var toml = try decode(std.testing.allocator, fbr.reader());
    defer toml.deinit();
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
