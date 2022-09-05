const std = @import("std");
const common = @import("toml_common.zig");

pub fn parse(reader: anytype, opt: ParseOptions) DecodeError!common.Table {
    const allocator = opt.allocator orelse @panic("TODO allow allocator to be optional");
    var parser = try Parser(@TypeOf(reader)).init(allocator, reader);
    defer parser.deinit();

    const result = try parser.parse();

    return result;
}

pub fn parseFree(val: *common.Table, opt: ParseOptions) void {
    val.deinit(opt.allocator orelse @panic(
        \\TODO detect when allocator is necessary or do whatever std.json does
    ));
}

pub const ParseOptions = struct {
    allocator: ?std.mem.Allocator,
};

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

        output: common.Table,
        defined_tables: NodeMap = .{},

        current_table: *common.Table,
        current_tree_node_map: *NodeMap,

        const TreeNode = struct {
            map: NodeMap = .{},
            defined_as: TreeNodeKind = .none,
        };
        const TreeNodeKind = enum { none, table, array_of_tables, final };
        const NodeMap = std.StringHashMapUnmanaged(TreeNode);

        fn init(allocator: std.mem.Allocator, reader: Reader) !ParserImpl {
            return ParserImpl{
                .allocator = allocator,
                .stack_fallback = std.heap.stackFallback(stack_fallback_size, allocator),
                .stream = Stream.init(reader),
                .output = common.Table{},
                .current_table = undefined,
                .current_tree_node_map = undefined,
            };
        }

        fn deinit(parser: *ParserImpl) void {
            deinitNodeMap(parser, &parser.defined_tables);
            parser.* = undefined;
        }

        fn deinitNodeMap(parser: *ParserImpl, map: *NodeMap) void {
            var i = map.iterator();
            while (i.next()) |entry| {
                deinitNodeMap(parser, &entry.value_ptr.map);
                parser.allocator.free(entry.key_ptr.*);
            }
            map.deinit(parser.allocator);
        }

        fn parse(parser: *ParserImpl) !common.Table {
            parser.current_table = &parser.output;
            parser.current_tree_node_map = &parser.defined_tables;
            errdefer parser.output.deinit(parser.allocator);

            while (!(try parser.isAtEof())) {
                try parser.skipWhitespace();
                if (try parser.matchNewLine()) continue;

                if (try parser.match('[')) {
                    if (try parser.match('[')) {
                        try parser.parseArrayOfTablesDefinition();
                    } else {
                        try parser.parseTableDefinition();
                    }
                } else {
                    try parser.matchKeyValuePair(parser.current_tree_node_map);
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

        fn check(parser: *ParserImpl, char: u8) !bool {
            if (try parser.readByte()) |byte| {
                try parser.stream.putBackByte(byte);
                return char == byte;
            }
            return false;
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

        fn matchKeyValuePair(parser: *ParserImpl, in_parent_tree_node: *NodeMap) !void {
            if (try parser.isAtEof()) return;

            var parent_tree_node = in_parent_tree_node;

            var current_table = parser.current_table;

            const value_ptr: *common.Value = while (true) {
                var out = std.ArrayList(u8).init(parser.stack_fallback.get());
                defer out.deinit();

                try parser.parseKeySegment(&out);
                try parser.skipWhitespace();

                const tree_entry = try parent_tree_node.getOrPut(parser.allocator, out.items);
                if (!tree_entry.found_existing) {
                    tree_entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                    tree_entry.value_ptr.* = .{};
                }

                parent_tree_node = &tree_entry.value_ptr.map;

                const entry = try current_table.table.getOrPut(parser.allocator, out.items);
                if (entry.found_existing and entry.value_ptr.* != .table) {
                    return error.duplicate_key;
                }
                if (!entry.found_existing) {
                    entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                }

                if (try parser.match('.')) {
                    try parser.skipWhitespace();

                    if (tree_entry.value_ptr.defined_as == .final) {
                        return error.duplicate_key;
                    }

                    if (!entry.found_existing) entry.value_ptr.* = .{ .table = .{} };
                    current_table = &entry.value_ptr.*.table;
                } else {
                    if (tree_entry.found_existing) {
                        return error.duplicate_key;
                    }
                    tree_entry.value_ptr.defined_as = .final;
                    break entry.value_ptr;
                }
            } else unreachable;

            try parser.consume('=', "Expected equals after key.", error.expected_equals);
            try parser.skipWhitespace();

            try parser.parseValue(value_ptr, parent_tree_node);

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

        fn parseValue(
            parser: *ParserImpl,
            value_ptr: *common.Value,
            parent_tree_node: *NodeMap,
        ) DecodeError!void {
            const sfa = parser.stack_fallback.get();
            try parser.ensureNotEof();

            if (try parser.match('"')) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();
                try parser.tokenizeString(.basic, .allow_multi, &out);
                value_ptr.* = .{ .string = try parser.allocator.dupe(u8, out.items) };
            } else if (try parser.match('\'')) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();
                try parser.tokenizeString(.literal, .allow_multi, &out);
                value_ptr.* = .{ .string = try parser.allocator.dupe(u8, out.items) };
            } else if (try parser.match('[')) {
                value_ptr.* = .{ .array = .{} };
                while (true) {
                    try parser.skipWhitespace();
                    if (try parser.matchNewLine()) continue;
                    if (try parser.check(']')) break;

                    var dummy_parent_tree_node: NodeMap = .{};
                    defer parser.deinitNodeMap(&dummy_parent_tree_node);

                    try value_ptr.array.append(parser.allocator, undefined);
                    try parser.parseValue(
                        &value_ptr.array.items[value_ptr.array.items.len - 1],
                        &dummy_parent_tree_node,
                    );

                    try parser.skipWhitespace();
                    while (try parser.matchNewLine()) try parser.skipWhitespace();

                    if (!(try parser.match(','))) break;
                }
                try parser.consume(']', "Expected ']' after list value.\n", error.expected_right_bracket);
            } else if (try parser.match('{')) {
                value_ptr.* = .{ .table = .{} };

                const previous_current_table = parser.current_table;
                parser.current_table = &value_ptr.*.table;
                defer parser.current_table = previous_current_table;

                try parser.skipWhitespace();
                if (!(try parser.match('}'))) {
                    while (true) {
                        try parser.skipWhitespace();
                        if (try parser.matchNewLine()) continue;

                        try parser.matchKeyValuePair(parent_tree_node);

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

        fn parseTableDefinition(parser: *ParserImpl) !void {
            const sfa = parser.stack_fallback.get();

            try parser.skipWhitespace();

            var current_table = &parser.output;
            var current_tree_node = &parser.defined_tables;

            while (true) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();

                try parser.parseKeySegment(&out);
                try parser.skipWhitespace();

                const tree_entry = try current_tree_node.getOrPut(parser.allocator, out.items);
                if (!tree_entry.found_existing) {
                    tree_entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                    tree_entry.value_ptr.* = .{};
                }
                current_tree_node = &tree_entry.value_ptr.map;

                const entry = try current_table.table.getOrPut(parser.allocator, out.items);
                if (!entry.found_existing) {
                    entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                    entry.value_ptr.* = .{ .table = .{} };
                    current_table = &entry.value_ptr.*.table;
                } else if (entry.value_ptr.* == .table) {
                    current_table = &entry.value_ptr.*.table;
                } else if (entry.value_ptr.* == .array) {
                    const arr = entry.value_ptr.array.items;
                    const last_val = &arr[arr.len - 1];
                    if (last_val.* != .table) {
                        return error.duplicate_key;
                    } else {
                        current_table = &last_val.table;
                    }
                } else {
                    return error.duplicate_key;
                }

                if (try parser.match('.')) {
                    if (tree_entry.value_ptr.defined_as == .final) {
                        return error.duplicate_key;
                    }
                    try parser.skipWhitespace();
                } else {
                    if (tree_entry.found_existing and tree_entry.value_ptr.defined_as != .none) {
                        return error.duplicate_key;
                    }
                    tree_entry.value_ptr.defined_as = .table;
                    break;
                }
            }

            parser.current_table = current_table;
            parser.current_tree_node_map = current_tree_node;

            try parser.skipWhitespace();

            try parser.consume(']', "Expected ']' after table key.", error.expected_right_bracket);

            try parser.skipWhitespace();
            try parser.consumeNewLineOrEof();
        }

        fn parseArrayOfTablesDefinition(parser: *ParserImpl) !void {
            const sfa = parser.stack_fallback.get();

            try parser.skipWhitespace();

            var current_table = &parser.output;
            var current_tree_node = &parser.defined_tables;

            while (true) {
                var out = std.ArrayList(u8).init(sfa);
                defer out.deinit();

                try parser.parseKeySegment(&out);
                try parser.skipWhitespace();

                const tree_entry = try current_tree_node.getOrPut(parser.allocator, out.items);
                if (!tree_entry.found_existing) {
                    tree_entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                    tree_entry.value_ptr.* = .{};
                }
                current_tree_node = &tree_entry.value_ptr.map;

                const entry = try current_table.table.getOrPut(parser.allocator, out.items);
                if (!entry.found_existing) {
                    entry.key_ptr.* = try parser.allocator.dupe(u8, out.items);
                }

                if (try parser.match('.')) {
                    if (tree_entry.value_ptr.defined_as == .final) {
                        return error.duplicate_key;
                    }

                    try parser.skipWhitespace();
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .{ .table = .{} };
                        current_table = &entry.value_ptr.*.table;
                    } else if (entry.value_ptr.* == .table) {
                        current_table = &entry.value_ptr.*.table;
                    } else if (entry.value_ptr.* == .array) {
                        const arr = entry.value_ptr.array.items;
                        const last_val = &arr[arr.len - 1];
                        if (last_val.* != .table) {
                            return error.duplicate_key;
                        } else {
                            current_table = &last_val.table;
                        }
                    } else {
                        return error.duplicate_key;
                    }
                } else {
                    const is_none_or_aot = tree_entry.value_ptr.defined_as == .none or tree_entry.value_ptr.defined_as == .array_of_tables;
                    if (tree_entry.found_existing and !is_none_or_aot) {
                        return error.duplicate_key;
                    }
                    tree_entry.value_ptr.defined_as = .array_of_tables;
                    parser.deinitNodeMap(&tree_entry.value_ptr.map);
                    tree_entry.value_ptr.map = .{};
                    current_tree_node = &tree_entry.value_ptr.map;

                    if (!entry.found_existing) {
                        entry.value_ptr.* = .{ .array = .{} };
                        try entry.value_ptr.array.append(parser.allocator, .{ .table = .{} });
                        current_table = &entry.value_ptr.array.items[entry.value_ptr.array.items.len - 1].table;
                    } else if (entry.value_ptr.* == .array) {
                        try entry.value_ptr.array.append(parser.allocator, .{ .table = .{} });
                        current_table = &entry.value_ptr.array.items[entry.value_ptr.array.items.len - 1].table;
                    } else {
                        return error.duplicate_key;
                    }
                    break;
                }
            }

            parser.current_table = current_table;
            parser.current_tree_node_map = current_tree_node;

            try parser.skipWhitespace();

            try parser.consume(']', "Expected ']]' after array of tables key.", error.expected_right_bracket);
            try parser.consume(']', "Expected ']]' after array of tables key.", error.expected_right_bracket);

            try parser.skipWhitespace();
            try parser.consumeNewLineOrEof();
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
            const is_multi = try parser.matchMulti(delimiter, null);

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
                        if (try parser.matchMulti(delimiter, out))
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

        fn matchMulti(parser: *ParserImpl, delimiter: u8, out: ?*std.ArrayList(u8)) !bool {
            if (try parser.readByte()) |c| {
                if (c == delimiter) {
                    if (try parser.readByte()) |c2| {
                        if (c2 == delimiter) {
                            if (out) |o| {
                                while (try parser.match('"')) {
                                    try o.append('"');
                                }
                            }
                            return true;
                        }

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

            if (try parser.match('-')) {
                return parser.tokenizeDate(buf);
            }

            if (try parser.match(':')) {
                const time = try parser.tokenizeTime(buf, .skip_hour);
                return common.Value{ .local_time = time };
            }

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

        fn tokenizeDate(parser: *ParserImpl, buf: *std.ArrayList(u8)) !common.Value {
            if (buf.items.len != 4) return error.unexpected_character;
            const year = std.fmt.parseInt(u16, buf.items, 10) catch return error.unexpected_character;
            if (year >= 10000) return error.unexpected_character;

            buf.clearRetainingCapacity();
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const month = std.fmt.parseInt(u8, buf.items, 10) catch return error.unexpected_character;
            if (month >= 12) return error.unexpected_character;

            try parser.consume('-', "Expected '-' after month.", error.unexpected_character);

            buf.clearRetainingCapacity();
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const day = std.fmt.parseInt(u8, buf.items, 10) catch return error.unexpected_character;
            if (day >= 31) return error.unexpected_character;

            const local_date = common.LocalDate{ .year = year, .month = month, .day = day };
            buf.clearRetainingCapacity();

            const time = if ((try parser.match('T')) or (try parser.match('t'))) blk: {
                break :blk try parser.tokenizeTime(buf, .parse_hour);
            } else if (try parser.match(' ')) blk: {
                if (try parser.checkFn(std.ascii.isDigit)) {
                    break :blk try parser.tokenizeTime(buf, .parse_hour);
                }
                try parser.stream.putBackByte(' ');
                break :blk null;
            } else null;

            if (time == null) {
                return common.Value{ .local_date = local_date };
            }

            buf.clearRetainingCapacity();
            const offset: ?i32 = if ((try parser.match('Z')) or (try parser.match('z'))) blk: {
                break :blk 0;
            } else if (try parser.match('-')) blk: {
                const off = try parser.tokenizeOffset(buf);
                break :blk -off;
            } else if (try parser.match('+')) blk: {
                const off = try parser.tokenizeOffset(buf);
                break :blk off;
            } else null;

            if (offset == null) {
                return common.Value{ .local_datetime = .{ .date = local_date, .time = time.? } };
            }

            return common.Value{ .offset_datetime = .{
                .date = local_date,
                .time = time.?,
                .offset = offset.?,
            } };
        }

        const SkipHour = enum { skip_hour, parse_hour };

        fn tokenizeTime(
            parser: *ParserImpl,
            buf: *std.ArrayList(u8),
            skip_hour: SkipHour,
        ) !common.LocalTime {
            if (skip_hour != .skip_hour) {
                try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
                try buf.append((try parser.readByte()) orelse return error.unexpected_eof);

                try parser.consume(':', "Expect ':' after hour.", error.unexpected_character);
            }
            if (buf.items.len != 2) return error.unexpected_character;
            const h = std.fmt.parseInt(u8, buf.items, 10) catch return error.unexpected_character;
            if (h >= 24) return error.unexpected_character;

            buf.clearRetainingCapacity();
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const m = std.fmt.parseInt(u8, buf.items, 10) catch return error.unexpected_character;
            if (m >= 60) return error.unexpected_character;

            try parser.consume(':', "Expect ':' after minute.", error.unexpected_character);

            buf.clearRetainingCapacity();
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const s = std.fmt.parseInt(u8, buf.items, 10) catch return error.unexpected_character;
            if (s >= 60) return error.unexpected_character;

            buf.clearRetainingCapacity();
            const ms = if (try parser.match('.')) blk: {
                try parser.tokenizeInteger(buf, 10);
                const ms_buf = buf.items[0..@minimum(3, buf.items.len)];
                break :blk std.fmt.parseInt(u16, ms_buf, 10) catch return error.unexpected_character;
            } else 0;
            if (ms >= 1000) return error.unexpected_character;

            return common.LocalTime{ .hour = h, .minute = m, .second = s, .millisecond = ms };
        }

        fn tokenizeOffset(parser: *ParserImpl, buf: *std.ArrayList(u8)) !i32 {
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const h = std.fmt.parseInt(i32, buf.items, 10) catch return error.unexpected_character;
            if (h >= 24) return error.unexpected_character;

            try parser.consume(':', "Expect ':' after hour.", error.unexpected_character);

            buf.clearRetainingCapacity();
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            try buf.append((try parser.readByte()) orelse return error.unexpected_eof);
            const m = std.fmt.parseInt(i32, buf.items, 10) catch return error.unexpected_character;
            if (m >= 60) return error.unexpected_character;

            return h * 60 + m;
        }

        fn skipComment(parser: *ParserImpl) !void {
            while (true) {
                if (try parser.matchNewLine()) {
                    try parser.stream.putBackByte('\n');
                    break;
                } else {
                    if (try parser.readByte()) |c| {
                        if (std.ascii.isCntrl(c) and c != '\t') return error.unexpected_character;
                    } else break;
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
