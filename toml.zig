const lib = struct {
    usingnamespace @import("toml_common.zig");
    usingnamespace @import("toml_decoder.zig");
    usingnamespace @import("toml_encoder.zig");
};
pub usingnamespace lib;

const std = @import("std");

test "comment" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/comment.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "# This is not a comment", toml.get("another").?.string);
}

test "invalid 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 1.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.unexpected_eof, err);
}

test "invalid 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 2.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.expected_newline, err);
}

test "invalid 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 3.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.expected_key, err);
}

test "invalid 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 4.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.expected_value, err);
}

test "bare keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/bare keys.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("bare_key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("bare-key").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("1234").?.string);
}

test "quoted keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/quoted keys.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "value", toml.get("127.0.0.1").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("character encoding").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("ʎǝʞ").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("key2").?.string);
    try std.testing.expectEqualSlices(u8, "value", toml.get("quoted \"value\"").?.string);
}

test "empty keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 1.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "empty keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 2.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "blank", toml.get("").?.string);
}

test "dotted keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 1.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "Orange", toml.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "orange", toml.get("physical").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "round", toml.get("physical").?.table.get("shape").?.string);
    try std.testing.expectEqual(true, toml.get("site").?.table.get("google.com").?.boolean);
}

test "dotted keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 2.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "banana", toml.get("fruit").?.table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "yellow", toml.get("fruit").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "banana", toml.get("fruit").?.table.get("flavor").?.string);
}

test "repeat keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 1.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 2.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 3.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(true, toml.get("fruit").?.table.get("apple").?.table.get("smooth").?.boolean);
    try std.testing.expectEqual(@as(i64, 2), toml.get("fruit").?.table.get("orange").?.integer);
}

test "repeat keys 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 4.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "out of order 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 1.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "fruit", toml.get("apple").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "fruit", toml.get("orange").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thin", toml.get("apple").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "thick", toml.get("orange").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "red", toml.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "orange", toml.get("orange").?.table.get("color").?.string);
}

test "out of order 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 2.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "fruit", toml.get("apple").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thin", toml.get("apple").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "red", toml.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "fruit", toml.get("orange").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thick", toml.get("orange").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "orange", toml.get("orange").?.table.get("color").?.string);
}

test "dotted keys not floats" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys not floats.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "pi", toml.get("3").?.table.get("14159").?.string);
}

test "basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/basic strings 1.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "I'm a string. \"You can quote me\". Name\tJos\u{00E9}\nLocation\tSF.", toml.get("str").?.string);
}

test "multi-line basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "Roses are red\nViolets are blue", toml.get("str1").?.string);
}

test "multi-line basic strings 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 2.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
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
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    const expect = "The quick brown fox jumps over the lazy dog.";
    try std.testing.expectEqualSlices(u8, expect, toml.get("str1").?.string);
    try std.testing.expectEqualSlices(u8, expect, toml.get("str2").?.string);
    try std.testing.expectEqualSlices(u8, expect, toml.get("str3").?.string);
}

test "literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/literal strings 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "C:\\Users\\nodejs\\templates", toml.get("winpath").?.string);
    try std.testing.expectEqualSlices(u8, "\\\\ServerX\\admin$\\system32\\", toml.get("winpath2").?.string);
    try std.testing.expectEqualSlices(u8, "Tom \"Dubs\" Preston-Werner", toml.get("quoted").?.string);
    try std.testing.expectEqualSlices(u8, "<\\i\\c*\\s*>", toml.get("regex").?.string);
}

test "multi-line literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line literal strings 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
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
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8,
        \\Here are fifteen quotation marks: """""""""""""""
    , toml.get("quot15").?.string);
    try std.testing.expectEqualSlices(u8, "Here are fifteen apostrophes: '''''''''''''''", toml.get("apos15").?.string);
}

test "integers 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(99 == toml.get("int1").?.integer);
    try std.testing.expect(42 == toml.get("int2").?.integer);
    try std.testing.expect(0 == toml.get("int3").?.integer);
    try std.testing.expect(-17 == toml.get("int4").?.integer);
    try std.testing.expect(-11 == toml.get("-11").?.integer);
}

test "integers 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 2.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(1_000 == toml.get("int5").?.integer);
    try std.testing.expect(5_349_221 == toml.get("int6").?.integer);
    try std.testing.expect(53_49_221 == toml.get("int7").?.integer);
    try std.testing.expect(1_2_3_4_5 == toml.get("int8").?.integer);
}

test "integers 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 3.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
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
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 2.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats 3" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 3.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "floats invalid 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats invalid 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEquals(1, 0);
}

test "booleans 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/booleans 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(true, toml.get("bool1").?.boolean);
    try std.testing.expectEqual(false, toml.get("bool2").?.boolean);
}

test "offset date time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "offset date time 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 2.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local date time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date time 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local date 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "local time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local time 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqual(1, 0);
}

test "arrays 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 1.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    const integers = toml.get("integers").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), integers.len);
    try std.testing.expectEqual(@as(i64, 1), integers[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers[1].integer);
    try std.testing.expectEqual(@as(i64, 3), integers[2].integer);

    const colors = toml.get("colors").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), colors.len);
    try std.testing.expectEqualSlices(u8, "red", colors[0].string);
    try std.testing.expectEqualSlices(u8, "yellow", colors[1].string);
    try std.testing.expectEqualSlices(u8, "green", colors[2].string);

    const nested_ints = toml.get("nested_arrays_of_ints").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), nested_ints.len);
    try std.testing.expectEqual(@as(usize, 2), nested_ints[0].array.items.len);
    try std.testing.expectEqual(@as(i64, 1), nested_ints[0].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested_ints[0].array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 3), nested_ints[1].array.items.len);
    try std.testing.expectEqual(@as(i64, 3), nested_ints[1].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 4), nested_ints[1].array.items[1].integer);
    try std.testing.expectEqual(@as(i64, 5), nested_ints[1].array.items[2].integer);

    const nested_mixed = toml.get("nested_mixed_array").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), nested_mixed.len);
    try std.testing.expectEqual(@as(usize, 2), nested_mixed[0].array.items.len);
    try std.testing.expectEqual(@as(i64, 1), nested_mixed[0].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested_mixed[0].array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 3), nested_mixed[1].array.items.len);
    try std.testing.expectEqualSlices(u8, "a", nested_mixed[1].array.items[0].string);
    try std.testing.expectEqualSlices(u8, "b", nested_mixed[1].array.items[1].string);
    try std.testing.expectEqualSlices(u8, "c", nested_mixed[1].array.items[2].string);

    const strings = toml.get("string_array").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), strings.len);
    try std.testing.expectEqualSlices(u8, "all", strings[0].string);
    try std.testing.expectEqualSlices(u8, "strings", strings[1].string);
    try std.testing.expectEqualSlices(u8, "are the same", strings[2].string);
    try std.testing.expectEqualSlices(u8, "type", strings[3].string);

    // TODO numbers

    // TODO contributors
    // const contributors = toml.get("contributors").?.array.items;
    // try std.testing.expectEqual(@as(usize, 2), contributors.len);
    // try std.testing.expectEqualSlices(u8, "Foo Bar <foo@example.com>", contributors[0].string);
    // const contributors_more = contributors[1].table;
    // try std.testing.expectEqualSlices(u8, "Baz Qux", contributors_more.get("name").?.string);
    // try std.testing.expectEqualSlices(u8, "bazqux@example.com", contributors_more.get("email").?.string);
    // try std.testing.expectEqualSlices(u8, "https://example.com/bazqux", contributors_more.get("url").?.string);
}

test "arrays 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 2.toml"));
    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    const integers2 = toml.get("integers2").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), integers2.len);
    try std.testing.expectEqual(@as(i64, 1), integers2[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers2[1].integer);
    try std.testing.expectEqual(@as(i64, 3), integers2[2].integer);

    const integers3 = toml.get("integers3").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), integers3.len);
    try std.testing.expectEqual(@as(i64, 1), integers3[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers3[1].integer);
}

test "tables 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 1.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "some string", toml.get("table-1").?.table.get("key1").?.string);
    try std.testing.expectEqual(@as(i64, 123), toml.get("table-1").?.table.get("key2").?.integer);
    try std.testing.expectEqualSlices(u8, "another string", toml.get("table-2").?.table.get("key1").?.string);
    try std.testing.expectEqual(@as(i64, 456), toml.get("table-2").?.table.get("key2").?.integer);
}

test "tables 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 2.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "pug", toml.get("dog").?.table.get("tater.man").?.table.get("type").?.table.get("name").?.string);
}

test "tables 3" {
    if (true) return error.SkipZigTest; // TODO: temporarily allowing this
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 3.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

// TODO
// Since tables cannot be defined more than once, redefining such tables using a [table] header is not allowed.
// Likewise, using dotted keys to redefine tables already defined in [table] form is not allowed. The [table] form
// can, however, be used to define sub-tables within tables defined via dotted keys.

test "tables 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 4.toml"));
    const err = lib.decode(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.duplicate_key, err);
}

test "tables 5" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 5.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(toml.get("a").?.table.get("b").?.table.get("c").? == .table);
    try std.testing.expect(toml.get("d").?.table.get("e").?.table.get("f").? == .table);
    try std.testing.expect(toml.get("g").?.table.get("h").?.table.get("i").? == .table);
    try std.testing.expect(toml.get("j").?.table.get("ʞ").?.table.get("l").? == .table);
}

test "tables 6" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 6.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(toml.get("x").?.table.get("y").?.table.get("z").?.table.get("w").? == .table);
    try std.testing.expect(toml.get("x").? == .table);
}

test "tables 7" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 7.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(toml.get("fruit").?.table.get("apple").? == .table);
    try std.testing.expect(toml.get("animal").? == .table);
    try std.testing.expect(toml.get("fruit").?.table.get("orange").? == .table);
}

test "tables 8" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 8.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expect(toml.get("fruit").?.table.get("apple").? == .table);
    try std.testing.expect(toml.get("fruit").?.table.get("orange").? == .table);
    try std.testing.expect(toml.get("animal").? == .table);
}

test "tables 9" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 9.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "Fido", toml.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "pug", toml.get("breed").?.string);
    try std.testing.expectEqualSlices(u8, "Regina Dogman", toml.get("owner").?.table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "1999-08-04", toml.get("owner").?.table.get("member_since").?.string);
}

test "tables 10" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 10.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "red", toml.get("fruit").?.table.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqual(true, toml.get("fruit").?.table.get("apple").?.table.get("taste").?.table.get("sweet").?.boolean);
}

test "tables 11" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 11.toml"));

    var toml = try lib.decode(std.testing.allocator, stream.reader());
    defer toml.deinit();

    try std.testing.expectEqualSlices(u8, "red", toml.get("fruit").?.table.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqual(true, toml.get("fruit").?.table.get("apple").?.table.get("taste").?.table.get("sweet").?.boolean);
    try std.testing.expectEqual(true, toml.get("fruit").?.table.get("apple").?.table.get("texture").?.table.get("smooth").?.boolean);
}
