const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Environ = @import("process.zig").Environ;
const Interpreter = @import("interpreter.zig").Interpreter;
const VenvPex = @import("Virtualenv.zig").VenvPex;
const ZipFile = @import("zip.zig").Zip(std.fs.File.SeekableStream);
const cache = @import("cache.zig");
const fs = @import("fs.zig");
const parse_pex_info = @import("pex_info.zig").parse;

const log = std.log.scoped(.boot);

pub fn bootPexZWindows(alloc: anytype, python_exe_path: [*:0]const u8, pex_path: [*:0]const u8) !i32 {
    const allocator = alloc.allocator();

    const boot_spec = try setupBoot(allocator, python_exe_path, pex_path);
    defer boot_spec.deinit();

    // TODO: XXX: incorporate original argv.
    var process = std.process.Child.init(
        &.{ std.mem.span(boot_spec.python_exe), std.mem.span(boot_spec.main_py) },
        allocator,
    );
    switch (try process.spawnAndWait()) {
        .Exited => |code| return code,
        .Signal => |_| return -1, // -1 * sig,
        .Stopped => |_| {
            return -75;
        },
        .Unknown => |_| {
            return -76;
        },
    }
}

pub fn bootPexZPosix(
    alloc: anytype,
    timer: *?std.time.Timer,
    python_exe_path: [*:0]const u8,
    pex_path: [*:0]const u8,
    environ: ?Environ,
) !noreturn {
    const allocator = alloc.allocator();

    const envp: [*:null]?[*:0]const u8 = res: {
        if (environ) |env| {
            env.exportValues();
            break :res env.envp;
        } else {
            var env_map = try std.process.getEnvMap(allocator);
            defer env_map.deinit();
            const envp = try std.process.createNullDelimitedEnvMap(allocator, &env_map);
            break :res @ptrCast(envp.ptr);
        }
    };

    const boot_spec = try setupBoot(allocator, python_exe_path, pex_path);
    defer boot_spec.deinit();

    // TODO: XXX: incorporate original_argv.
    var argv = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 2);
    defer argv.deinit();

    try argv.append(boot_spec.python_exe);
    try argv.append(boot_spec.main_py);
    try argv.append(null);

    log.info("Bytes used: {d}", .{alloc.bytes_used()});
    if (timer.*) |*elpased| log.info(
        "C boot({s}, {s}, ...) pre-exec took {d:.3}µs",
        .{ python_exe_path, pex_path, elpased.read() / 1_000 },
    );
    return std.posix.execvpeZ(boot_spec.python_exe, @ptrCast(argv.items), envp);
}

const BootSpec = struct {
    allocator: std.mem.Allocator,
    python_exe: [*:0]const u8,
    main_py: [*:0]const u8,

    fn deinit(self: @This()) void {
        self.allocator.free(std.mem.span(self.python_exe));
        self.allocator.free(std.mem.span(self.main_py));
    }
};

fn setupBoot(
    allocator: std.mem.Allocator,
    python_exe_path: [*:0]const u8,
    pex_path: [*:0]const u8,
) !BootSpec {
    // [ ] 1. Check if current interpreter + PEX has cached venv and re-exec to it if so.
    //     + Load PEX-INFO to get: `pex_hash`.
    // [ ] 2. Find viable interpreter for PEX to create venv with.
    //     + Load PEX-INFO to get: `interpreter_constraints
    //     + Load PEX-INFO to get dep resolve info:
    //       * `distributions`
    //       * `requirements`
    //       * `overridden`
    //       * `excluded`
    // [ ] 3. Create venv.
    //     + Load PEX-INFO to get:
    //       * `venv_system_site_packages`
    //       * `venv_hermetic_scripts`
    //       * `venv_bin_path`
    // [ ] 4. Populate venv.
    //     + Load PEX-INFO to get dep install info:
    //       * `deps_are_wheel_files`
    //     + Load PEX-INFO to get __main__ info:
    //       * `entry_point`
    //       * `inherit_path
    //       * `inject_python_args``
    //       * `inject_args`
    //       * `inject_env`
    // [ ] 5. Re-exec to venv.

    const interpreter = try Interpreter.identify(allocator, std.mem.span(python_exe_path));
    defer interpreter.deinit();
    std.debug.print("{s}:\n{}\n", .{ interpreter.value.path, interpreter.value });

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    var pex_file = try std.fs.cwd().openFileZ(pex_path, .{});
    defer pex_file.close();
    const zip_stream = pex_file.seekableStream();
    var zip_file = try ZipFile.init(allocator, zip_stream);
    defer zip_file.deinit(allocator);

    const pex_info_entry = zip_file.entry("PEX-INFO") orelse {
        std.debug.print("Failed to find PEX-INFO in {s}\n", .{pex_path});
        return error.PexInfoNotFound;
    };

    const data = try pex_info_entry.extract_to_slice(allocator, zip_stream);
    defer allocator.free(data);

    const pex_info = try parse_pex_info(allocator, data);
    defer pex_info.deinit();

    const encoder = std.fs.base64_encoder;
    const pex_hash_bytes = @as(
        [20]u8,
        @bitCast(try std.fmt.parseUnsigned(u160, pex_info.value.pex_hash, 16)),
    );
    var encoded_pex_hash_buf: [27]u8 = undefined;
    std.debug.assert(encoded_pex_hash_buf.len == encoder.calcSize(pex_hash_bytes.len));
    const pex_hash = encoder.encode(&encoded_pex_hash_buf, &pex_hash_bytes);

    const pexcz_root = try cache.root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});

    var venv_cache_dir = try pexcz_root.join(&.{ "venvs", "0", pex_hash });
    defer venv_cache_dir.deinit(.{});

    const venv_pex: VenvPex = try .init(allocator, python_exe_path, pex_path, pex_info.value);
    defer venv_pex.deinit();

    const Fn = struct {
        fn install(work_path: []const u8, work_dir: std.fs.Dir, context: VenvPex) !void {
            std.debug.print("Installing {s} to {s}...\n", .{ context.pex_path, work_path });
            return context.install(work_dir);
        }
    };
    var dir = try venv_cache_dir.createAtomic(VenvPex, Fn.install, venv_pex, .{});
    defer dir.close();

    const python_exe = try std.fs.path.joinZ(
        allocator,
        &.{ venv_cache_dir.path, venv_pex.venv_python_relpath },
    );
    const main_py = try std.fs.path.joinZ(
        allocator,
        &.{ venv_cache_dir.path, VenvPex.main_py_relpath },
    );
    return .{ .allocator = allocator, .python_exe = python_exe, .main_py = main_py };
}
