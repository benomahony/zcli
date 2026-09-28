const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rich = b.dependency("zrich", .{ .target = target, .optimize = optimize }).module("zrich");
    const lib = b.addModule("zcli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrich", .module = rich }},
    });
    const example = b.addExecutable(.{ .name = "parcel", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/parcel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zcli", .module = lib }},
    }) });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.step.dependOn(b.getInstallStep());
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run.addPassthruArgs() else if (b.args) |args| run.addArgs(args);
    b.step("run", "Refresh installed parcel binary and run it").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = lib });
    b.step("test", "Run unit and reusable conformance tests").dependOn(&b.addRunArtifact(tests).step);
    const process_tests = b.addSystemCommand(&.{"python3"});
    process_tests.addFileArg(b.path("tests/process_test.py"));
    process_tests.addArtifactArg(example);
    b.step("conformance", "Test real processes, pipes, TTYs, and dry runs").dependOn(&process_tests.step);
}
