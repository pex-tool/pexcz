const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Environ = @import("process.zig").Environ;
const Interpreter = @import("interpreter.zig").Interpreter;
const VenvPex = @import("VenvPex.zig");
const Virtualenv = @import("Virtualenv.zig");
const Zip = @import("Zip.zig");
const cache = @import("cache.zig");
const fs = @import("fs.zig");
const PexInfo = @import("PexInfo.zig");

const log = std.log.scoped(.boot);

pub fn bootPexZWindows(
    alloc: anytype,
    python_exe_path: [*:0]const u8,
    pex_path: [*:0]const u8,
) !i32 {
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
    argv: [][*:0]u8,
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
    if (timer.*) |*elapsed| log.debug("Create envp took {d:.3}µs", .{elapsed.read() / 1_000});

    const boot_spec = try setupBoot(allocator, python_exe_path, pex_path);
    defer boot_spec.deinit();
    if (timer.*) |*elapsed| {
        log.debug("Calculate boot spec took {d:.3}µs", .{elapsed.read() / 1_000});
    }

    var exec_argv = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 2 + argv.len);
    defer exec_argv.deinit();

    try exec_argv.append(boot_spec.python_exe);
    try exec_argv.append(boot_spec.main_py);
    if (argv.len > 2) {
        for (argv[2..]) |arg| {
            try exec_argv.append(arg);
        }
    }
    try exec_argv.append(null);

    log.debug("Bytes used: {d}", .{alloc.bytesUsed()});
    if (timer.*) |*elpased| log.debug(
        "C boot({s}, {s}, ...) pre-exec took {d:.3}µs",
        .{ python_exe_path, pex_path, elpased.read() / 1_000 },
    );
    return std.posix.execvpeZ(boot_spec.python_exe, @ptrCast(exec_argv.items), envp);
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

    var timer = try std.time.Timer.start();

    const interpreter = try Interpreter.identify(allocator, std.mem.span(python_exe_path));
    defer interpreter.deinit();
    log.debug("Identify interpreter took {d:.3}µs.", .{timer.lap() / 1_000});

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    timer.reset();
    var zip_file = try Zip.init(pex_path, .{});
    defer zip_file.deinit();

    const pex_info_data = zip_file.extractToSlice(allocator, "PEX-INFO") catch |err| {
        log.err("Failed to read PEX-INFO from {s}: {}", .{ pex_path, err });
        return error.PexInfoUnreadable;
    } orelse {
        log.err("Failed to find PEX-INFO in {s}.", .{pex_path});
        return error.PexInfoNotFound;
    };
    defer allocator.free(pex_info_data);
    log.debug("Extract PEX-INFO took {d:.3}µs.", .{timer.lap() / 1_000});

    const pex_info = try PexInfo.parse(allocator, pex_info_data);
    defer pex_info.deinit();
    log.debug("Parse PEX-INFO took {d:.3}µs.", .{timer.lap() / 1_000});

    const encoder = std.fs.base64_encoder;
    const pex_hash_bytes = @as(
        [20]u8,
        @bitCast(try std.fmt.parseUnsigned(u160, pex_info.value.pex_hash, 16)),
    );

    // TODO: XXX: Account for PEX_PATH
    var venv_digest = std.crypto.hash.Sha1.init(.{});
    venv_digest.update(&pex_hash_bytes);
    const tag = interpreter.value.supported_tags[0];
    venv_digest.update(tag.python);
    venv_digest.update(tag.abi);
    venv_digest.update(tag.platform);
    const venv_hash_bytes = venv_digest.finalResult();

    var encoded_venv_hash_buf: [27]u8 = undefined;
    std.debug.assert(encoded_venv_hash_buf.len == encoder.calcSize(venv_hash_bytes.len));
    const pex_hash = encoder.encode(&encoded_venv_hash_buf, &venv_hash_bytes);

    const pexcz_root = try cache.root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});

    var venv_cache_dir = try pexcz_root.join(&.{ "venvs", "0", pex_hash });
    defer venv_cache_dir.deinit(.{});

    const venv_pex: VenvPex = try .init(pex_path, pex_info.value, pex_info_data);

    const Fn = struct {
        allocator: std.mem.Allocator,
        venv_pex: VenvPex,
        dest_path: []const u8,
        interpreter: Interpreter,

        const Self = @This();

        fn install(work_path: []const u8, work_dir: std.fs.Dir, self: Self) !void {
            log.debug("Installing {s} to {s}.\n", .{ self.venv_pex.pex_path, work_path });
            const venv = try self.venv_pex.install(
                self.allocator,
                self.dest_path,
                work_path,
                work_dir,
                self.interpreter,
                false,
            );
            venv.deinit();
        }
    };
    const func: Fn = .{
        .allocator = allocator,
        .venv_pex = venv_pex,
        .dest_path = venv_cache_dir.path,
        .interpreter = interpreter.value,
    };
    var dir = try venv_cache_dir.createAtomic(Fn, Fn.install, func, .{});
    defer dir.close();

    const venv = try Virtualenv.load(allocator, dir);
    defer venv.deinit();

    const python_exe = try std.fs.path.joinZ(
        allocator,
        &.{ venv_cache_dir.path, venv.interpreter_relpath },
    );
    const main_py = try std.fs.path.joinZ(
        allocator,
        &.{ venv_cache_dir.path, "__main__.py" },
    );
    return .{ .allocator = allocator, .python_exe = python_exe, .main_py = main_py };
}
