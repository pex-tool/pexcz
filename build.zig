const std = @import("std");

const supported_targets: []const std.Target.Query = &.{
    // Linux targets:
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .arm, .os_tag = .linux },
    .{ .cpu_arch = .powerpc64le, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    // Macos targets:
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    // Windows targets:
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

const VIRTUALENV_PY_RESOURCE_BASE_NAME = "virtualenv_16.7.12_py";

pub fn build(b: *std.Build) !void {
    const Targets = enum {
        All,
        Current,
    };
    const requested_tgts = b.option(
        Targets,
        "targets",
        "Which targets to include boot shims for.",
    ) orelse Targets.Current;

    const optimize = b.standardOptimizeOption(.{});

    const cur_tgt_query = b.standardTargetOptionsQueryOnly(.{ .whitelist = supported_targets });
    const cur_tgt = b.resolveTargetQuery(cur_tgt_query);
    const target_queries = switch (requested_tgts) {
        .All => supported_targets,
        .Current => &.{cur_tgt_query},
    };

    const tool = b.addExecutable(.{
        .name = "fetch_virtualenv",
        .root_source_file = b.path("tools/fetch_virtualenv.zig"),
        .target = b.graph.host,
    });
    const tool_step = b.addRunArtifact(tool);
    // TODO(John Sirois): Plumb --sha arg from a build option.
    const virtualenv_py_resource = tool_step.addOutputFileArg(VIRTUALENV_PY_RESOURCE_BASE_NAME);
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");

    for (target_queries) |tq| {
        const rt = b.resolveTargetQuery(tq);

        const lib = b.addModule("pexcz", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = rt,
            .optimize = optimize,
        });
        lib.addAnonymousImport("virtualenv.py", .{ .root_source_file = virtualenv_py_resource });
        lib.addImport("known-folders", known_folders);

        const clib = b.addSharedLibrary(.{
            .name = "pexcz",
            .root_module = b.addModule("pexcz", .{
                .root_source_file = b.path("src/clib.zig"),
                .target = rt,
                .optimize = optimize,
            }),
        });
        clib.root_module.addImport("pexcz", lib);

        const clib_output = b.addInstallArtifact(clib, .{
            .dest_dir = .{
                .override = .{
                    .custom = try std.fs.path.join(
                        b.allocator,
                        &[_][]const u8{ "lib", try tq.zigTriple(b.allocator) },
                    ),
                },
            },
        });
        b.getInstallStep().dependOn(&clib_output.step);

        const exe = b.addExecutable(.{
            .name = "pexcz",
            .root_module = b.addModule("pexcz", .{
                .root_source_file = b.path("src/main.zig"),
                .target = rt,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("pexcz", lib);
        const exe_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try std.fs.path.join(b.allocator, &.{
                        "bin",
                        try tq.zigTriple(b.allocator),
                    }),
                },
            },
        });
        b.getInstallStep().dependOn(&exe_output.step);

        if (cur_tgt.result.os.tag == rt.result.os.tag and cur_tgt.result.cpu.arch == rt.result.cpu.arch) {
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&run_cmd.step);
        }
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = cur_tgt,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("known-folders", known_folders);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = cur_tgt,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
