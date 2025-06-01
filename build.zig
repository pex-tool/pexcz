const std = @import("std");

// TODO: XXX: Uncomment musl variants and arm (32 bit). There are currently issues building
//  libzip / zstd / zlib.
const supported_targets: []const std.Target.Query = &.{
    // Linux targets:
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    // .{ .cpu_arch = .arm, .os_tag = .linux },
    .{ .cpu_arch = .powerpc64le, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .powerpc64le, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    // Macos targets:
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    // Windows targets:
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

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
    tool_step.addCheck(.{.expect_term = .{.Exited = 0}});
    // TODO(John Sirois): Plumb --sha arg from a build option.
    const virtualenv_py_resource = tool_step.addOutputFileArg("virtualenv.py");

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");

    var target_dirs = try std.ArrayList([]const u8).initCapacity(b.allocator, target_queries.len);
    defer target_dirs.deinit();

    var options = b.addOptions();
    for (target_queries) |tq| {
        const target_dir = try tq.zigTriple(b.allocator);
        try target_dirs.append(target_dir);
    }
    options.addOption([]const []const u8, "libs", target_dirs.items);
    options.addOptionPath("libs_root", b.path("src"));
    const config = options.createModule();

    var update_source_files = b.addUpdateSourceFiles();

    for (target_queries, target_dirs.items) |tq, target_dir| {
        const rt = b.resolveTargetQuery(tq);

        const libzip_dep = try build_libzip(b, rt, optimize);

        const lib = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = rt,
            .optimize = optimize,
        });
        lib.addAnonymousImport("virtualenv.py", .{ .root_source_file = virtualenv_py_resource });
        lib.addImport("known-folders", known_folders);
        lib.linkLibrary(libzip_dep);

        const clib = b.addSharedLibrary(.{
            .name = "pexcz",
            .root_module = b.addModule("pexcz", .{
                .root_source_file = b.path("src/clib.zig"),
                .target = rt,
                .optimize = optimize,
            }),
        });
        clib.root_module.addImport("pexcz", lib);

        const library_name = try std.fmt.allocPrint(
            b.allocator,
            "{s}pexcz{s}",
            .{ rt.result.libPrefix(), rt.result.dynamicLibSuffix() },
        );
        const sub_path = try std.fs.path.join(b.allocator, &.{ "src", ".lib", target_dir, library_name });
        update_source_files.addCopyFileToSource(clib.getEmittedBin(), sub_path);
        options.addOptionPath(target_dir, b.path(sub_path));

        var clib_output = b.addInstallArtifact(clib, .{});
        clib_output.dest_dir = .lib;
        clib_output.dest_sub_path = b.pathJoin(&.{ target_dir, clib_output.dest_sub_path });
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
        exe.root_module.addImport("config", config);
        exe.step.dependOn(&update_source_files.step);
        var exe_output = b.addInstallArtifact(exe, .{});
        exe_output.dest_sub_path = b.pathJoin(&.{ target_dir, exe_output.dest_sub_path });
        b.getInstallStep().dependOn(&exe_output.step);

        if (cur_tgt.result.os.tag == rt.result.os.tag and
            cur_tgt.result.cpu.arch == rt.result.cpu.arch and
            cur_tgt.result.abi == rt.result.abi)
        {
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&run_cmd.step);
        }

        const zip_exe = b.addExecutable(.{
            .name = "zipopen",
            .root_module = b.addModule("zipopen", .{
                .root_source_file = b.path("bench/zipopen.zig"),
                .target = rt,
                .optimize = optimize,
            }),
        });
        zip_exe.root_module.addImport("pexcz", lib);
        zip_exe.linkLibC();
        const zip_exe_output = b.addInstallArtifact(zip_exe, .{});
        zip_exe_output.dest_sub_path = b.pathJoin(&.{ target_dir, zip_exe_output.dest_sub_path });
        b.getInstallStep().dependOn(&zip_exe_output.step);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = cur_tgt,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addAnonymousImport(
        "virtualenv.py",
        .{ .root_source_file = virtualenv_py_resource },
    );
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

fn build_libzip(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const upstream = b.dependency("libzip", .{});
    const config = b.addConfigHeader(
        .{ .style = .{ .cmake = upstream.path("config.h.in") } },
        .{
            .SIZEOF_OFF_T = @sizeOf(usize),
            .SIZEOF_SIZE_T = @sizeOf(usize),

            .CMAKE_PROJECT_NAME = "libzip",
            .CMAKE_PROJECT_VERSION = "1.1.4",

            .HAVE_LIBZSTD = true,
        },
    );
    const zip_config = b.addConfigHeader(
        .{ .style = .{ .cmake = upstream.path("zipconf.h.in") } },
        .{
            .libzip_VERSION = "1.11.4",
            .libzip_VERSION_MAJOR = 1,
            .libzip_VERSION_MINOR = 11,
            .libzip_VERSION_PATCH = 4,

            .LIBZIP_TYPES_INCLUDE =
            \\#if !defined(__STDC_FORMAT_MACROS)
            \\#define __STDC_FORMAT_MACROS 1
            \\#endif
            \\#include <inttypes.h>
            ,
            .ZIP_INT8_T = "int8_t",
            .ZIP_UINT8_T = "uint8_t",
            .ZIP_INT16_T = "int16_t",
            .ZIP_UINT16_T = "uint16_t",
            .ZIP_INT32_T = "int32_t",
            .ZIP_UINT32_T = "uint32_t",
            .ZIP_INT64_T = "int64_t",
            .ZIP_UINT64_T = "uint64_t",
        },
    );
    const lib = b.addStaticLibrary(.{
        .name = "zip",
        .target = target,
        .optimize = optimize,
    });
    const zip_lib_dir = upstream.path("lib");
    const flags: []const []const u8 = res: {
        if (target.result.os.tag == .windows) {
            break :res &.{
                "-DHAVE_FTELLO",
                "-DHAVE_UNISTD_H",
                "-DHAVE__SNWPRINTF_S",
                "-Dzip_EXPORTS",
            };
        } else {
            break :res &.{
                "-DHAVE_FTELLO",
                "-DHAVE_UNISTD_H",
                "-Dzip_EXPORTS",
            };
        }
    };
    lib.addCSourceFiles(.{
        .root = zip_lib_dir,
        .files = &.{
            "zip_add.c",
            "zip_add_dir.c",
            "zip_add_entry.c",
            "zip_algorithm_deflate.c",
            "zip_algorithm_zstd.c",
            "zip_buffer.c",
            "zip_close.c",
            "zip_delete.c",
            "zip_dir_add.c",
            "zip_dirent.c",
            "zip_discard.c",
            "zip_entry.c",
            "zip_error.c",
            "zip_error_clear.c",
            "zip_error_get.c",
            "zip_error_get_sys_type.c",
            "zip_error_strerror.c",
            "zip_error_to_str.c",
            "zip_extra_field.c",
            "zip_extra_field_api.c",
            "zip_fclose.c",
            "zip_fdopen.c",
            "zip_file_add.c",
            "zip_file_error_clear.c",
            "zip_file_error_get.c",
            "zip_file_get_comment.c",
            "zip_file_get_external_attributes.c",
            "zip_file_get_offset.c",
            "zip_file_rename.c",
            "zip_file_replace.c",
            "zip_file_set_comment.c",
            "zip_file_set_encryption.c",
            "zip_file_set_external_attributes.c",
            "zip_file_set_mtime.c",
            "zip_file_strerror.c",
            "zip_fopen.c",
            "zip_fopen_encrypted.c",
            "zip_fopen_index.c",
            "zip_fopen_index_encrypted.c",
            "zip_fread.c",
            "zip_fseek.c",
            "zip_ftell.c",
            "zip_get_archive_comment.c",
            "zip_get_archive_flag.c",
            "zip_get_encryption_implementation.c",
            "zip_get_file_comment.c",
            "zip_get_name.c",
            "zip_get_num_entries.c",
            "zip_get_num_files.c",
            "zip_hash.c",
            "zip_io_util.c",
            "zip_libzip_version.c",
            "zip_memdup.c",
            "zip_name_locate.c",
            "zip_new.c",
            "zip_open.c",
            "zip_pkware.c",
            "zip_progress.c",
            "zip_realloc.c",
            "zip_rename.c",
            "zip_replace.c",
            "zip_set_archive_comment.c",
            "zip_set_archive_flag.c",
            "zip_set_default_password.c",
            "zip_set_file_comment.c",
            "zip_set_file_compression.c",
            "zip_set_name.c",
            "zip_source_accept_empty.c",
            "zip_source_begin_write.c",
            "zip_source_begin_write_cloning.c",
            "zip_source_buffer.c",
            "zip_source_call.c",
            "zip_source_close.c",
            "zip_source_commit_write.c",
            "zip_source_compress.c",
            "zip_source_crc.c",
            "zip_source_error.c",
            "zip_source_file_common.c",
            "zip_source_file_stdio.c",
            "zip_source_free.c",
            "zip_source_function.c",
            "zip_source_get_dostime.c",
            "zip_source_get_file_attributes.c",
            "zip_source_is_deleted.c",
            "zip_source_layered.c",
            "zip_source_open.c",
            "zip_source_pass_to_lower_layer.c",
            "zip_source_pkware_decode.c",
            "zip_source_pkware_encode.c",
            "zip_source_read.c",
            "zip_source_remove.c",
            "zip_source_rollback_write.c",
            "zip_source_seek.c",
            "zip_source_seek_write.c",
            "zip_source_stat.c",
            "zip_source_supports.c",
            "zip_source_tell.c",
            "zip_source_tell_write.c",
            "zip_source_window.c",
            "zip_source_write.c",
            "zip_source_zip.c",
            "zip_source_zip_new.c",
            "zip_stat.c",
            "zip_stat_index.c",
            "zip_stat_init.c",
            "zip_strerror.c",
            "zip_string.c",
            "zip_unchange.c",
            "zip_unchange_all.c",
            "zip_unchange_archive.c",
            "zip_unchange_data.c",
            "zip_utf-8.c",
        },
        .flags = flags,
    });
    if (target.result.os.tag == .windows) {
        lib.addCSourceFiles(.{
            .root = zip_lib_dir,
            .files = &.{
                "zip_source_file_win32.c",
                "zip_source_file_win32_named.c",
                "zip_source_file_win32_utf16.c",
                "zip_source_file_win32_utf8.c",
                "zip_source_file_win32_ansi.c",
                "zip_random_win32.c",
            },
            .flags = flags,
        });
    } else {
        lib.addCSourceFiles(.{
            .root = zip_lib_dir,
            .files = &.{
                "zip_source_file_stdio_named.c",
                "zip_random_unix.c",
            },
            .flags = flags,
        });
    }
    lib.addIncludePath(zip_lib_dir);
    lib.addConfigHeader(config);
    lib.addConfigHeader(zip_config);

    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibrary(zlib_dep.artifact("z"));

    const zstd_dependency = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
        .minify = true,
        .dictbuilder = false,
        .@"exclude-compressors-dfast-and-up" = true,
        .@"exclude-compressors-greedy-and-up" = true,
    });
    lib.linkLibrary(zstd_dependency.artifact("zstd"));

    lib.linkLibC();

    const tool = b.addExecutable(.{
        .name = "generate_zip_error_strings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_zip_error_strings.zig"),
            .target = b.graph.host,
        }),
    });
    const tool_step = b.addRunArtifact(tool);
    tool_step.addPrefixedFileArg("-S", b.path("tools/generate_zip_error_strings.py"));
    tool_step.addPrefixedDirectoryArg("-I", zip_lib_dir);
    const zip_err_str = tool_step.addOutputFileArg("zip_err_str.c");
    lib.addCSourceFile(.{ .file = zip_err_str, .flags = flags });

    lib.installHeadersDirectory(zip_lib_dir, "", .{
        .include_extensions = &.{
            "zip.h",
        },
    });
    lib.installHeader(zip_config.getOutput(), "zipconf.h");
    return lib;
}
