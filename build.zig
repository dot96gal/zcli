const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zctx_dep = b.dependency("zctx", .{ .target = target, .optimize = optimize });
    const zctx_mod = zctx_dep.module("zctx");
    b.modules.put(b.allocator, "zctx", zctx_mod) catch @panic("OOM");

    const zcli_mod = b.addModule("zcli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcli_mod.addImport("zctx", zctx_mod);

    const basic_exe = b.addExecutable(.{
        .name = "example-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/basic/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcli", .module = zcli_mod },
            },
        }),
    });
    b.installArtifact(basic_exe);
    const run_basic = b.addRunArtifact(basic_exe);
    run_basic.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_basic.addArgs(args);
    const run_basic_step = b.step("run-basic", "Run basic example (no cancellation)");
    run_basic_step.dependOn(&run_basic.step);

    const signal_exe = b.addExecutable(.{
        .name = "example-signal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/signal/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcli", .module = zcli_mod },
                .{ .name = "zctx", .module = zctx_mod },
            },
        }),
    });
    b.installArtifact(signal_exe);
    const run_signal = b.addRunArtifact(signal_exe);
    run_signal.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_signal.addArgs(args);
    const run_signal_step = b.step("run-signal", "Run signal cancel example");
    run_signal_step.dependOn(&run_signal.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zctx", .module = zctx_mod },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const lib = b.addLibrary(.{
        .name = "zcli",
        .root_module = zcli_mod,
        .linkage = .static,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build API documentation");
    docs_step.dependOn(&install_docs.step);
}
