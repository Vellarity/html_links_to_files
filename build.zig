const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

const BuildAll = enum { all, one };

pub fn build(b: *std.Build) void {
    const build_all_option = b.option(BuildAll, "build-all", "build one version or all") orelse BuildAll.one;

    switch (build_all_option) {
        .all => {
            build_all(b);
        },
        .one => {
            build_one(b);
        },
    }
}

fn build_all(b: *std.Build) void {
    //const targets = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.graph.host;
    const install_step = b.getInstallStep();

    var has_native_target = false;

    for (targets) |t| {
        const cpu: [:0]const u8 = @tagName(t.cpu_arch.?);
        const os: [:0]const u8 = @tagName(t.os_tag.?);

        const name = b.fmt("links_to_files_{s}_{s}", .{ cpu, os });

        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(t),
            .optimize = optimize,
        });

        const clap = b.dependency("clap", .{});
        exe.root_module.addImport("clap", clap.module("clap"));

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = b.fmt("{s}_{s}", .{ cpu, os }),
                },
            },
        });
        install_step.dependOn(&target_output.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&target_output.step);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const is_native_target = t.cpu_arch.? == native_target.result.cpu.arch and t.os_tag.? == native_target.result.os.tag;

        if (is_native_target) {
            const run_step = b.step("run", "Run native version of the app");
            run_step.dependOn(&run_cmd.step);
            has_native_target = true;
        }
    }

    if (!has_native_target) {
        std.debug.print("Warning: No native target found in the targets list\n", .{});
    }
}

fn build_one(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "links_to_files",
        .root_module = exe_mod,
    });

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
