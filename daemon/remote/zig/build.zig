const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseFast;
    const version = b.option([]const u8, "version", "daemon version string") orelse "dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("tls", dep.module("tls"));
    }

    const exe = b.addExecutable(.{
        .name = "cmuxd-remote",
        .root_module = mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests: real `serve_unix`-shaped listener on a temp Unix
    // socket, driven via line-delimited JSON-RPC. See tests/integration.zig.
    const integration_src_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test_exports.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_src_mod.addOptions("build_options", build_options);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_src_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_src_mod.addImport("tls", dep.module("tls"));
    }

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("cmuxd_src", integration_src_mod);

    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    integration_tests.linkLibC();
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit + integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
