const toml = struct {
    usingnamespace @import("toml_common.zig");
    usingnamespace @import("toml_decoder.zig");
    usingnamespace @import("toml_encoder.zig");
};
pub usingnamespace toml;

const std = @import("std");

test "comment" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/comment.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "value", doc.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "# This is not a comment", doc.get("another").?.string);
}

test "invalid 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 1.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.unexpected_eof, err);
}

test "invalid 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 2.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.expected_newline, err);
}

test "invalid 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.expected_key, err);
}

test "invalid 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/invalid 4.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.expected_value, err);
}

test "bare keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/bare keys.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "value", doc.get("key").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("bare_key").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("bare-key").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("1234").?.string);
}

test "quoted keys" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/quoted keys.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "value", doc.get("127.0.0.1").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("character encoding").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("ʎǝʞ").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("key2").?.string);
    try std.testing.expectEqualSlices(u8, "value", doc.get("quoted \"value\"").?.string);
}

test "empty keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "blank", doc.get("").?.string);
}

test "empty keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/empty keys 2.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "blank", doc.get("").?.string);
}

test "dotted keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "Orange", doc.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "orange", doc.get("physical").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "round", doc.get("physical").?.table.get("shape").?.string);
    try std.testing.expectEqual(true, doc.get("site").?.table.get("google.com").?.boolean);
}

test "dotted keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys 2.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "banana", doc.get("fruit").?.table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "yellow", doc.get("fruit").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "banana", doc.get("fruit").?.table.get("flavor").?.string);
}

test "repeat keys 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 1.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 2.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "repeat keys 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 3.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(true, doc.get("fruit").?.table.get("apple").?.table.get("smooth").?.boolean);
    try std.testing.expectEqual(@as(i64, 2), doc.get("fruit").?.table.get("orange").?.integer);
}

test "repeat keys 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/repeat keys 4.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "out of order 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "fruit", doc.get("apple").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "fruit", doc.get("orange").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thin", doc.get("apple").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "thick", doc.get("orange").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "red", doc.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "orange", doc.get("orange").?.table.get("color").?.string);
}

test "out of order 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/out of order 2.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "fruit", doc.get("apple").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thin", doc.get("apple").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "red", doc.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "fruit", doc.get("orange").?.table.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "thick", doc.get("orange").?.table.get("skin").?.string);
    try std.testing.expectEqualSlices(u8, "orange", doc.get("orange").?.table.get("color").?.string);
}

test "dotted keys not floats" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/dotted keys not floats.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "pi", doc.get("3").?.table.get("14159").?.string);
}

test "basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/basic strings 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "I'm a string. \"You can quote me\". Name\tJos\u{00E9}\nLocation\tSF.", doc.get("str").?.string);
}

test "multi-line basic strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "Roses are red\nViolets are blue", doc.get("str1").?.string);
}

test "multi-line basic strings 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8,
        \\Here are two quotation marks: "". Simple enough.
    , doc.get("str4").?.string);
    try std.testing.expectEqualSlices(u8,
        \\Here are three quotation marks: """.
    , doc.get("str5").?.string);
    try std.testing.expectEqualSlices(u8,
        \\Here are fifteen quotation marks: """"""""""""""".
    , doc.get("str6").?.string);
}

test "multi-line basic strings line ending backslash" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line basic strings line ending backslash.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const expect = "The quick brown fox jumps over the lazy dog.";
    try std.testing.expectEqualSlices(u8, expect, doc.get("str1").?.string);
    try std.testing.expectEqualSlices(u8, expect, doc.get("str2").?.string);
    try std.testing.expectEqualSlices(u8, expect, doc.get("str3").?.string);
}

test "literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/literal strings 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "C:\\Users\\nodejs\\templates", doc.get("winpath").?.string);
    try std.testing.expectEqualSlices(u8, "\\\\ServerX\\admin$\\system32\\", doc.get("winpath2").?.string);
    try std.testing.expectEqualSlices(u8, "Tom \"Dubs\" Preston-Werner", doc.get("quoted").?.string);
    try std.testing.expectEqualSlices(u8, "<\\i\\c*\\s*>", doc.get("regex").?.string);
}

test "multi-line literal strings 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line literal strings 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "I [dw]on't need \\d{2} apples", doc.get("regex2").?.string);
    try std.testing.expectEqualSlices(u8,
        \\The first newline is
        \\trimmed in raw strings.
        \\   All other whitespace
        \\   is preserved.
        \\
    , doc.get("lines").?.string);
}

test "multi-line literal strings 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/multi-line literal strings 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8,
        \\Here are fifteen quotation marks: """""""""""""""
    , doc.get("quot15").?.string);
    try std.testing.expectEqualSlices(u8, "Here are fifteen apostrophes: '''''''''''''''", doc.get("apos15").?.string);
}

test "integers 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(99 == doc.get("int1").?.integer);
    try std.testing.expect(42 == doc.get("int2").?.integer);
    try std.testing.expect(0 == doc.get("int3").?.integer);
    try std.testing.expect(-17 == doc.get("int4").?.integer);
    try std.testing.expect(-11 == doc.get("-11").?.integer);
}

test "integers 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(1_000 == doc.get("int5").?.integer);
    try std.testing.expect(5_349_221 == doc.get("int6").?.integer);
    try std.testing.expect(53_49_221 == doc.get("int7").?.integer);
    try std.testing.expect(1_2_3_4_5 == doc.get("int8").?.integer);
}

test "integers 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/integers 3.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(0xDEADBEEF == doc.get("hex1").?.integer);
    try std.testing.expect(0xdeadbeef == doc.get("hex2").?.integer);
    try std.testing.expect(0xdead_beef == doc.get("hex3").?.integer);
    try std.testing.expect(0o01234567 == doc.get("oct1").?.integer);
    try std.testing.expect(0o755 == doc.get("oct2").?.integer);
    try std.testing.expect(0b11010110 == doc.get("bin1").?.integer);
}

test "floats 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(@as(f64, 1.0), doc.get("flt1").?.float);
    try std.testing.expectEqual(@as(f64, 3.1415), doc.get("flt2").?.float);
    try std.testing.expectEqual(@as(f64, -0.01), doc.get("flt3").?.float);
    try std.testing.expectEqual(@as(f64, 5e22), doc.get("flt4").?.float);
    try std.testing.expectEqual(@as(f64, 1e06), doc.get("flt5").?.float);
    try std.testing.expectEqual(@as(f64, -2e-2), doc.get("flt6").?.float);
    try std.testing.expectEqual(@as(f64, 6.626e-34), doc.get("flt7").?.float);
}

test "floats 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(@as(f64, 224_617.445_991_228), doc.get("flt8").?.float);
}

test "floats 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/floats 3.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(std.math.inf_f64, doc.get("sf1").?.float);
    try std.testing.expectEqual(std.math.inf_f64, doc.get("sf2").?.float);
    try std.testing.expectEqual(-std.math.inf_f64, doc.get("sf3").?.float);
    try std.testing.expect(std.math.isNan(doc.get("sf4").?.float));
    try std.testing.expect(std.math.isNan(doc.get("sf5").?.float));
    try std.testing.expect(std.math.isNan(doc.get("sf6").?.float));
}

test "floats invalid 1" {
    var stream = std.io.fixedBufferStream("invalid_float_1 = .7");
    var err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.expected_value, err);

    stream = std.io.fixedBufferStream("invalid_float_2 = 7.");
    err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.unexpected_eof, err);

    stream = std.io.fixedBufferStream("invalid_float_3 = 3.e+20");
    err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.unexpected_character, err);
}

test "booleans 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/booleans 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(true, doc.get("bool1").?.boolean);
    try std.testing.expectEqual(false, doc.get("bool2").?.boolean);
}

test "offset date time 1" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(1, 0);
}

test "offset date time 2" {
    if (true) return error.SkipZigTest;
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/offset date time 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(1, 0);
}

test "local date time 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date time 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const ldt1 = doc.get("ldt1").?.local_datetime;
    try std.testing.expectEqual(@as(u64, 1979), ldt1.date.year);
    try std.testing.expectEqual(@as(u64, 5), ldt1.date.month);
    try std.testing.expectEqual(@as(u64, 27), ldt1.date.day);
    try std.testing.expectEqual(@as(u64, 7), ldt1.time.hour);
    try std.testing.expectEqual(@as(u64, 32), ldt1.time.minute);
    try std.testing.expectEqual(@as(u64, 0), ldt1.time.second);
    try std.testing.expectEqual(@as(u64, 0), ldt1.time.millisecond);

    const ldt2 = doc.get("ldt2").?.local_datetime;
    try std.testing.expectEqual(@as(u64, 1979), ldt2.date.year);
    try std.testing.expectEqual(@as(u64, 5), ldt2.date.month);
    try std.testing.expectEqual(@as(u64, 27), ldt2.date.day);
    try std.testing.expectEqual(@as(u64, 0), ldt2.time.hour);
    try std.testing.expectEqual(@as(u64, 32), ldt2.time.minute);
    try std.testing.expectEqual(@as(u64, 0), ldt2.time.second);
    try std.testing.expectEqual(@as(u64, 999), ldt2.time.millisecond);
}

test "local date 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local date 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const ld1 = doc.get("ld1").?.local_date;
    try std.testing.expectEqual(@as(u64, 1979), ld1.year);
    try std.testing.expectEqual(@as(u64, 5), ld1.month);
    try std.testing.expectEqual(@as(u64, 27), ld1.day);
}

test "local time 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/local time 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const lt1 = doc.get("lt1").?.local_time;
    try std.testing.expectEqual(@as(u64, 7), lt1.hour);
    try std.testing.expectEqual(@as(u64, 32), lt1.minute);
    try std.testing.expectEqual(@as(u64, 0), lt1.second);
    try std.testing.expectEqual(@as(u64, 0), lt1.millisecond);

    const lt2 = doc.get("lt2").?.local_time;
    try std.testing.expectEqual(@as(u64, 0), lt2.hour);
    try std.testing.expectEqual(@as(u64, 32), lt2.minute);
    try std.testing.expectEqual(@as(u64, 0), lt2.second);
    try std.testing.expectEqual(@as(u64, 999), lt2.millisecond);
}

test "arrays 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 1.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const integers = doc.get("integers").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), integers.len);
    try std.testing.expectEqual(@as(i64, 1), integers[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers[1].integer);
    try std.testing.expectEqual(@as(i64, 3), integers[2].integer);

    const colors = doc.get("colors").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), colors.len);
    try std.testing.expectEqualSlices(u8, "red", colors[0].string);
    try std.testing.expectEqualSlices(u8, "yellow", colors[1].string);
    try std.testing.expectEqualSlices(u8, "green", colors[2].string);

    const nested_ints = doc.get("nested_arrays_of_ints").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), nested_ints.len);
    try std.testing.expectEqual(@as(usize, 2), nested_ints[0].array.items.len);
    try std.testing.expectEqual(@as(i64, 1), nested_ints[0].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested_ints[0].array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 3), nested_ints[1].array.items.len);
    try std.testing.expectEqual(@as(i64, 3), nested_ints[1].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 4), nested_ints[1].array.items[1].integer);
    try std.testing.expectEqual(@as(i64, 5), nested_ints[1].array.items[2].integer);

    const nested_mixed = doc.get("nested_mixed_array").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), nested_mixed.len);
    try std.testing.expectEqual(@as(usize, 2), nested_mixed[0].array.items.len);
    try std.testing.expectEqual(@as(i64, 1), nested_mixed[0].array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested_mixed[0].array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 3), nested_mixed[1].array.items.len);
    try std.testing.expectEqualSlices(u8, "a", nested_mixed[1].array.items[0].string);
    try std.testing.expectEqualSlices(u8, "b", nested_mixed[1].array.items[1].string);
    try std.testing.expectEqualSlices(u8, "c", nested_mixed[1].array.items[2].string);

    const strings = doc.get("string_array").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), strings.len);
    try std.testing.expectEqualSlices(u8, "all", strings[0].string);
    try std.testing.expectEqualSlices(u8, "strings", strings[1].string);
    try std.testing.expectEqualSlices(u8, "are the same", strings[2].string);
    try std.testing.expectEqualSlices(u8, "type", strings[3].string);

    const numbers = doc.get("numbers").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), numbers.len);
    try std.testing.expectEqual(@as(f64, 0.1), numbers[0].float);
    try std.testing.expectEqual(@as(f64, 0.2), numbers[1].float);
    try std.testing.expectEqual(@as(f64, 0.5), numbers[2].float);
    try std.testing.expectEqual(@as(i64, 1), numbers[3].integer);
    try std.testing.expectEqual(@as(i64, 2), numbers[4].integer);
    try std.testing.expectEqual(@as(i64, 5), numbers[5].integer);

    const contributors = doc.get("contributors").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), contributors.len);
    try std.testing.expectEqualSlices(u8, "Foo Bar <foo@example.com>", contributors[0].string);
    const contributors_more = contributors[1].table;
    try std.testing.expectEqualSlices(u8, "Baz Qux", contributors_more.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "bazqux@example.com", contributors_more.get("email").?.string);
    try std.testing.expectEqualSlices(u8, "https://example.com/bazqux", contributors_more.get("url").?.string);
}

test "arrays 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 2.toml"));
    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const integers2 = doc.get("integers2").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), integers2.len);
    try std.testing.expectEqual(@as(i64, 1), integers2[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers2[1].integer);
    try std.testing.expectEqual(@as(i64, 3), integers2[2].integer);

    const integers3 = doc.get("integers3").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), integers3.len);
    try std.testing.expectEqual(@as(i64, 1), integers3[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers3[1].integer);
}

test "arrays 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/arrays 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "tables 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "some string", doc.get("table-1").?.table.get("key1").?.string);
    try std.testing.expectEqual(@as(i64, 123), doc.get("table-1").?.table.get("key2").?.integer);
    try std.testing.expectEqualSlices(u8, "another string", doc.get("table-2").?.table.get("key1").?.string);
    try std.testing.expectEqual(@as(i64, 456), doc.get("table-2").?.table.get("key2").?.integer);
}

test "tables 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 2.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "pug", doc.get("dog").?.table.get("tater.man").?.table.get("type").?.table.get("name").?.string);
}

test "tables 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "tables 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 4.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "tables 5" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 5.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(doc.get("a").?.table.get("b").?.table.get("c").? == .table);
    try std.testing.expect(doc.get("d").?.table.get("e").?.table.get("f").? == .table);
    try std.testing.expect(doc.get("g").?.table.get("h").?.table.get("i").? == .table);
    try std.testing.expect(doc.get("j").?.table.get("ʞ").?.table.get("l").? == .table);
}

test "tables 6" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 6.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(doc.get("x").?.table.get("y").?.table.get("z").?.table.get("w").? == .table);
    try std.testing.expect(doc.get("x").? == .table);
}

test "tables 7" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 7.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(doc.get("fruit").?.table.get("apple").? == .table);
    try std.testing.expect(doc.get("animal").? == .table);
    try std.testing.expect(doc.get("fruit").?.table.get("orange").? == .table);
}

test "tables 8" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 8.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expect(doc.get("fruit").?.table.get("apple").? == .table);
    try std.testing.expect(doc.get("fruit").?.table.get("orange").? == .table);
    try std.testing.expect(doc.get("animal").? == .table);
}

test "tables 9" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 9.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "Fido", doc.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "pug", doc.get("breed").?.string);
    try std.testing.expectEqualSlices(u8, "Regina Dogman", doc.get("owner").?.table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "1999-08-04", doc.get("owner").?.table.get("member_since").?.string);
}

test "tables 10" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 10.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "red", doc.get("fruit").?.table.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqual(true, doc.get("fruit").?.table.get("apple").?.table.get("taste").?.table.get("sweet").?.boolean);
}

test "tables 11" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/tables 11.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "red", doc.get("fruit").?.table.get("apple").?.table.get("color").?.string);
    try std.testing.expectEqual(true, doc.get("fruit").?.table.get("apple").?.table.get("taste").?.table.get("sweet").?.boolean);
    try std.testing.expectEqual(true, doc.get("fruit").?.table.get("apple").?.table.get("texture").?.table.get("smooth").?.boolean);
}

test "inline tables 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/inline tables 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    try std.testing.expectEqualSlices(u8, "Tom", doc.get("name").?.table.get("first").?.string);
    try std.testing.expectEqualSlices(u8, "Preston-Werner", doc.get("name").?.table.get("last").?.string);
    try std.testing.expectEqual(@as(i64, 1), doc.get("point").?.table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), doc.get("point").?.table.get("y").?.integer);
    try std.testing.expectEqualSlices(u8, "pug", doc.get("animal").?.table.get("type").?.table.get("name").?.string);
}

test "inline tables 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/inline tables 2.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "inline tables 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/inline tables 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "inline tables 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/inline tables 4.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const points = doc.get("points").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), points.len);
    try std.testing.expectEqual(@as(i64, 1), points[0].table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), points[0].table.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 3), points[0].table.get("z").?.integer);
    try std.testing.expectEqual(@as(i64, 7), points[1].table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 8), points[1].table.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 9), points[1].table.get("z").?.integer);
    try std.testing.expectEqual(@as(i64, 2), points[2].table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 4), points[2].table.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 8), points[2].table.get("z").?.integer);
}

test "array of tables 1" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/array of tables 1.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const products = doc.get("products").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), products.len);
    try std.testing.expectEqualSlices(u8, "Hammer", products[0].table.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 738594937), products[0].table.get("sku").?.integer);
    try std.testing.expectEqualSlices(u8, "Nail", products[2].table.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 284758393), products[2].table.get("sku").?.integer);
    try std.testing.expectEqualSlices(u8, "gray", products[2].table.get("color").?.string);
}

test "array of tables 2" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/array of tables 2.toml"));

    var doc = try toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    defer toml.parseFree(&doc, .{ .allocator = std.testing.allocator });

    const fruits = doc.get("fruits").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), fruits.len);
    try std.testing.expectEqualSlices(u8, "apple", fruits[0].table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "red", fruits[0].table.get("physical").?.table.get("color").?.string);
    try std.testing.expectEqualSlices(u8, "round", fruits[0].table.get("physical").?.table.get("shape").?.string);
    const apple_varieties = fruits[0].table.get("varieties").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), apple_varieties.len);
    try std.testing.expectEqualSlices(u8, "red delicious", apple_varieties[0].table.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "granny smith", apple_varieties[1].table.get("name").?.string);

    try std.testing.expectEqualSlices(u8, "banana", fruits[1].table.get("name").?.string);
    const banana_varieties = fruits[1].table.get("varieties").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), banana_varieties.len);
    try std.testing.expectEqualSlices(u8, "plantain", banana_varieties[0].table.get("name").?.string);
}

test "array of tables 3" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/array of tables 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "array of tables 4" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/array of tables 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "array of tables 5" {
    var stream = std.io.fixedBufferStream(@embedFile("test_fixtures/array of tables 3.toml"));
    const err = toml.parse(stream.reader(), .{ .allocator = std.testing.allocator });
    try std.testing.expectError(error.duplicate_key, err);
}

test "stringify numbers" {
    const Bort = struct { la_bufa: i32, la_yusa: f64, laysa: f32, morgan: f32 };
    var bort = Bort{
        .la_bufa = 123,
        .la_yusa = -3.52,
        .laysa = std.math.nan_f32,
        .morgan = -std.math.inf_f32,
    };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\la_bufa = 123
        \\la_yusa = -3.52
        \\laysa = nan
        \\morgan = -inf
        \\
    ;
    try toml.stringify(Bort, bort, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify strings" {
    const Foo = struct { bar: []const u8, baz: [:0]const u8 };
    var foo = Foo{ .bar = "d(-.-)b", .baz = "\x0E" };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\bar = "d(-.-)b"
        \\baz = "\U0000000e"
        \\
    ;
    try toml.stringify(Foo, foo, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify bools" {
    const Foo = struct { bar: bool, baz: bool };
    var foo = Foo{ .bar = false, .baz = true };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\bar = false
        \\baz = true
        \\
    ;
    try toml.stringify(Foo, foo, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify array" {
    const Foo = struct { bar: [2]f64 };
    const foo = Foo{ .bar = .{ 6.9, 4.20 } };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\bar = [ 6.9, 4.2 ]
        \\
    ;
    try toml.stringify(Foo, foo, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify table" {
    const Hola = struct { a: i64, b: bool, c: []const u8 };
    const Adios = struct { a: bool, b: Hola, c: f64 };
    const saludo = Adios{ .a = false, .b = .{ .a = 333, .b = true, .c = "oculto" }, .c = 1.0 };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\a = false
        \\c = 1.0
        \\[b]
        \\a = 333
        \\b = true
        \\c = "oculto"
        \\
    ;
    try toml.stringify(Adios, saludo, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify array of tables" {
    const Hola = struct { a: i64, b: []const u8 };
    const Adios = struct { a: bool, b: []const Hola, c: f64 };
    const saludo = Adios{ .a = true, .b = &[_]Hola{
        .{ .a = 333, .b = "oculto" },
        .{ .a = 24, .b = "extraño" },
        .{ .a = -289, .b = "lejano" },
    }, .c = -1.0 };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const expected =
        \\a = true
        \\c = -1.0
        \\[[b]]
        \\a = 333
        \\b = "oculto"
        \\[[b]]
        \\a = 24
        \\b = "extraño"
        \\[[b]]
        \\a = -289
        \\b = "lejano"
        \\
    ;
    try toml.stringify(Adios, saludo, buffer.writer());
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

test "stringify quoted key" {
    const Foo = struct { @"b a r": i32 };
    var foo = Foo{ .@"b a r" = 0 };

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try toml.stringify(Foo, foo, buffer.writer());
    try std.testing.expectEqualSlices(u8, "\"b a r\" = 0\n", buffer.items);
}
