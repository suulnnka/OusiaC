//! occ 构建脚本(宿主可执行文件)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const exe = b.addExecutable(.{
        .name = "occ",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run occ");
    run_step.dependOn(&run_cmd.step);
}
