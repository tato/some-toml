const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "toml",
    .source = .{ .path = src_dir ++ "/toml.zig" },
};

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const main_tests = b.addTest("toml.zig");
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.addPackage(pkg);

    b.step("test", "Run library tests").dependOn(&main_tests.step);
}

fn getSrcDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
const src_dir = getSrcDir();
