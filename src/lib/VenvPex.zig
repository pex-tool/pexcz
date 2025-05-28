const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Interpreter = @import("interpreter.zig").Interpreter;
const PexInfo = @import("PexInfo.zig");
const Tag = @import("Tag.zig");
const VENV_PEX_PY = @embedFile("venv_pex.py");
const Virtualenv = @import("Virtualenv.zig");
const WheelInfo = @import("WheelInfo.zig");
const Zip = @import("Zip.zig");
const installed_wheel = @import("installed_wheel.zig");

pub const main_py_relpath = "__main__.py";

pex_path: [*c]const u8,
pex_info: PexInfo,

const Self = @This();

pub fn init(pex_path: [*c]const u8, pex_info: PexInfo) !Self {
    return .{ .pex_path = std.mem.span(pex_path), .pex_info = pex_info };
}

const log = std.log.scoped(.venv_pex);

const WheelLayout = struct {
    // N.B.: The full PEX installed wheel chroot layout as of this writing:
    // {
    //   "fingerprint": "a9e2c24b6a2fad1b6f19dd0af921302834025951844ee6392a7a2d5a87b62bf3",
    //   "record_relpath": "cowsay-5.0.dist-info/RECORD",
    //   "root_is_purelib": true,
    //   "stash_dir": ".prefix"
    // }
    stash_dir: ?[]const u8 = null,
};

const WheelToInstall = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    stash_dir: ?[]const u8,

    fn deinit(self: @This()) void {
        self.allocator.free(self.prefix);
        if (self.stash_dir) |stash_dir| {
            self.allocator.free(stash_dir);
        }
    }
};

const WheelsToInstall = struct {
    allocator: std.mem.Allocator,
    entries: []const WheelToInstall,

    fn deinit(self: WheelsToInstall) void {
        for (self.entries) |entry| {
            entry.deinit();
        }
        self.allocator.free(self.entries);
    }

    fn shouldExtract(self: WheelsToInstall, entry_name: []const u8) bool {
        for (self.entries) |entry| {
            if (std.mem.startsWith(u8, entry_name, entry.prefix)) {
                return true;
            }
        }
        return false;
    }
};

fn selectWheelsToInstall(
    self: Self,
    allocator: std.mem.Allocator,
    interpreter: Interpreter,
    zip: *Zip,
) !WheelsToInstall {
    var timer = try std.time.Timer.start();
    defer log.info(
        "VenvPex.selectWheelsToInstall({s}, ...) took {d:.3}ms",
        .{ self.pex_path, timer.read() / 1_000_000 },
    );

    var ranked_tags = try interpreter.rankedTags(allocator);
    defer ranked_tags.deinit();

    var wheels_to_install = try std.ArrayList(WheelToInstall).initCapacity(
        allocator,
        self.pex_info.distributions.map.count(),
    );
    errdefer wheels_to_install.deinit();

    for (self.pex_info.distributions.map.keys()) |wheel_name| {
        const wheel_info = try WheelInfo.parse(allocator, wheel_name);
        defer wheel_info.deinit();

        for (wheel_info.tags) |tag| {
            if (ranked_tags.rank(tag)) |rank| {
                log.info(
                    "{d} {s} {s} (raw: {s}) <- {s} matches {s}",
                    .{
                        rank,
                        tag,
                        wheel_info.project_name.value,
                        wheel_info.project_name.raw,
                        wheel_name,
                        interpreter.path,
                    },
                );
                const wheel_prefix = try std.fmt.allocPrint(allocator, ".deps/{s}", .{wheel_name});

                const wheel_layout = try std.fmt.allocPrintZ(
                    allocator,
                    "{s}/.layout.json",
                    .{wheel_prefix},
                );
                defer allocator.free(wheel_layout);

                var stash_dir: ?[]const u8 = null;
                if (try zip.extractToSlice(allocator, wheel_layout)) |layout_data| {
                    const layout = try std.json.parseFromSlice(
                        WheelLayout,
                        allocator,
                        layout_data,
                        .{ .ignore_unknown_fields = true },
                    );
                    defer layout.deinit();
                    if (layout.value.stash_dir) |stash_dir_relpath| {
                        stash_dir = try allocator.dupe(u8, stash_dir_relpath);
                    }
                }
                try wheels_to_install.append(
                    WheelToInstall{
                        .allocator = allocator,
                        .prefix = wheel_prefix,
                        .stash_dir = stash_dir,
                    },
                );
            }
        }
    }
    return .{ .allocator = allocator, .entries = try wheels_to_install.toOwnedSlice() };
}

pub fn install(
    self: Self,
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    work_path: []const u8,
    work_dir: std.fs.Dir,
    interpreter: Interpreter,
    include_pip: bool,
) !Virtualenv {
    var timer = try std.time.Timer.start();
    defer log.info(
        "VenvPex.install({s}, ...) took {d:.3}ms",
        .{ self.pex_path, timer.read() / 1_000_000 },
    );

    var zip = try Zip.init(self.pex_path, .{});
    defer zip.deinit();

    const wheels_to_install = try self.selectWheelsToInstall(
        allocator,
        interpreter,
        &zip,
    );
    defer wheels_to_install.deinit();

    const venv = try Virtualenv.create(allocator, interpreter, work_dir, include_pip);
    errdefer venv.deinit();

    const site_packages_path = try std.fs.path.join(
        allocator,
        &.{ work_path, venv.site_packages_relpath },
    );
    defer allocator.free(site_packages_path);

    try zip.parallelExtract(
        allocator,
        site_packages_path,
        wheels_to_install,
        WheelsToInstall.shouldExtract,
        .{},
    );
    log.info("VenvPex unzip took {d:.3}ms", .{timer.read() / 1_000_000});

    const ErrInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));
    var worker_err = std.atomic.Value(ErrInt).init(0);

    const Installer = struct {
        fn installSafe(
            alloc: std.mem.Allocator,
            errored: *std.atomic.Value(ErrInt),
            wp: []const u8,
            virtualenv: *const Virtualenv,
            site_packages_dir_path: []const u8,
            entry_name: []const u8,
        ) void {
            if (errored.load(.seq_cst) > 0) {
                return;
            }
            return installed_wheel.installInVenv(
                alloc,
                wp,
                virtualenv,
                site_packages_dir_path,
                entry_name,
            ) catch |err| {
                errored.store(@intFromError(err), .seq_cst);
                log.err(
                    "[{d}] Failed to install wheel {s}: {}",
                    .{ std.Thread.getCurrentId(), entry_name, err },
                );
            };
        }
    };

    var site_packages_dir = try work_dir.makeOpenPath(venv.site_packages_relpath, .{});
    defer site_packages_dir.close();

    var deps_dir = try site_packages_dir.openDir(".deps", .{ .iterate = true });
    defer deps_dir.close();

    var deps = std.ArrayList([]const u8).init(allocator);
    defer {
        for (deps.items) |dep| {
            allocator.free(dep);
        }
        deps.deinit();
    }

    var deps_dir_iter = deps_dir.iterate();
    while (try deps_dir_iter.next()) |dep_entry| {
        if (dep_entry.kind == .directory and std.mem.endsWith(u8, dep_entry.name, ".whl")) {
            try deps.append(try allocator.dupe(u8, dep_entry.name));
        }
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(
        .{
            .allocator = allocator,
            .n_jobs = @min(zip.num_entries, std.Thread.getCpuCount() catch 1),
        },
    );
    defer pool.deinit();

    var alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
    var wg: std.Thread.WaitGroup = .{};
    for (deps.items) |dep| {
        const err_int = worker_err.load(.seq_cst);
        if (err_int > 0) {
            return @errorFromInt(err_int);
        }
        pool.spawnWg(
            &wg,
            Installer.installSafe,
            .{ alloc.allocator(), &worker_err, work_path, &venv, site_packages_path, dep },
        );
    }
    pool.waitAndWork(&wg);
    const err_int = worker_err.load(.seq_cst);
    if (err_int > 0) {
        return @errorFromInt(err_int);
    }
    log.info("VenvPex unzip and spread took {d:.3}ms", .{timer.read() / 1_000_000});

    try site_packages_dir.deleteTree(".deps");

    // TODO: XXX: Unhack script installation - actually use entry_point.txt metadata and deal with Windows.
    if (native_os != .windows) {
        if (std.fs.path.dirname(venv.interpreter_relpath)) |scripts_dir_path| {
            var scripts_dir = try work_dir.openDir(scripts_dir_path, .{ .iterate = true });
            defer scripts_dir.close();

            var scripts_dir_iter = scripts_dir.iterate();
            while (try scripts_dir_iter.next()) |script_entry| {
                if (script_entry.kind != .file) {
                    continue;
                }
                const script = try scripts_dir.openFile(script_entry.name, .{});
                defer script.close();

                var script_fp = std.io.bufferedReader(script.reader());
                var script_reader = script_fp.reader();
                if ('#' != try script_reader.readByte()) {
                    continue;
                }
                if ('!' != try script_reader.readByte()) {
                    continue;
                }

                var buf: [4096]u8 = undefined;
                var shebang_writer = std.io.fixedBufferStream(&buf);

                try script_reader.streamUntilDelimiter(
                    shebang_writer.writer(),
                    '\n',
                    std.fs.max_path_bytes,
                );
                const shebang = shebang_writer.getWritten();

                const python = std.mem.eql(u8, "python", shebang);
                const python_cr = !python and (native_os == .windows and std.mem.eql(
                    u8,
                    "python\r",
                    shebang,
                ));
                if (!python and !python_cr) {
                    continue;
                }

                const rewritten_script_name = try std.fmt.allocPrint(
                    allocator,
                    ".{s}.rewrite",
                    .{script_entry.name},
                );
                defer allocator.free(rewritten_script_name);

                const rewritten_script = try scripts_dir.createFile(rewritten_script_name, .{});
                errdefer rewritten_script.close();

                var rewritten_script_fp = std.io.bufferedWriter(
                    rewritten_script.writer(),
                );
                var rewritten_script_writer = rewritten_script_fp.writer();
                try rewritten_script_writer.writeAll("#!");
                try rewritten_script_writer.writeAll(dest_path);
                try rewritten_script_writer.writeByte(std.fs.path.sep);
                try rewritten_script_writer.writeAll(venv.interpreter_relpath);
                if (python_cr) {
                    try rewritten_script_writer.writeAll('\r');
                }
                try rewritten_script_writer.writeByte('\n');
                while (true) {
                    const amount = try script_reader.read(&buf);
                    if (amount == 0) {
                        break;
                    }
                    try rewritten_script_writer.writeAll(buf[0..amount]);
                }
                try rewritten_script_fp.flush();

                const metadata = try rewritten_script.metadata();
                var permissions = metadata.permissions();
                permissions.inner.unixSet(.user, .{ .execute = true });
                permissions.inner.unixSet(.group, .{ .execute = true });
                permissions.inner.unixSet(.other, .{ .execute = true });
                try rewritten_script.setPermissions(permissions);
                rewritten_script.close();

                try scripts_dir.rename(rewritten_script_name, script_entry.name);
            }
        }
    }

    log.info(
        "VenvPex unzip and spread and script re-write took {d:.3}ms",
        .{timer.read() / 1_000_000},
    );

    const main_py = try work_dir.createFile(Self.main_py_relpath, .{});
    errdefer main_py.close();

    var main_py_fp = std.io.bufferedWriter(main_py.writer());
    var main_py_writer = main_py_fp.writer();

    try main_py_writer.writeAll("#!");
    try main_py_writer.writeAll(dest_path);
    try main_py_writer.writeByte(std.fs.path.sep);
    try main_py_writer.writeAll(venv.interpreter_relpath);
    try main_py_writer.writeByte('\n');

    try main_py_writer.writeAll(VENV_PEX_PY);

    const bin_path = res: {
        if (self.pex_info.venv_bin_path) |value| {
            break :res @tagName(value);
        } else {
            break :res "false";
        }
    };

    const inject_env = env_res: {
        if (self.pex_info.inject_env.map.count() == 0) {
            break :env_res "";
        }
        var inject_env_buf = std.ArrayList(u8).init(allocator);
        var inject_env_writer = inject_env_buf.writer();
        var entry_iter = self.pex_info.inject_env.map.iterator();
        while (entry_iter.next()) |entry| {
            try inject_env_writer.writeByte('"');
            try inject_env_writer.writeAll(entry.key_ptr.*);
            try inject_env_writer.writeAll("\":\"");
            try inject_env_writer.writeAll(entry.value_ptr.*);
            try inject_env_writer.writeAll("\",");
        }
        break :env_res try inject_env_buf.toOwnedSlice();
    };
    defer if (inject_env.len > 0) allocator.free(inject_env);

    const inject_args = args_res: {
        if (self.pex_info.inject_args.len == 0) {
            break :args_res "";
        }
        var inject_args_buf = std.ArrayList(u8).init(allocator);
        var inject_args_writer = inject_args_buf.writer();
        for (self.pex_info.inject_args) |arg| {
            try inject_args_writer.writeByte('"');
            try inject_args_writer.writeAll(arg);
            try inject_args_writer.writeAll("\",");
        }
        break :args_res try inject_args_buf.toOwnedSlice();
    };
    defer if (inject_args.len > 0) allocator.free(inject_args);

    var entry_point: ?[]const u8 = null;
    defer if (entry_point) |ep| allocator.free(ep);
    if (self.pex_info.entry_point) |ep| {
        entry_point = try std.mem.join(allocator, ep, &.{ "\"", "\"" });
    }

    var script: ?[]const u8 = null;
    defer if (script) |name| allocator.free(name);
    if (self.pex_info.script) |name| {
        script = try std.mem.join(allocator, name, &.{ "\"", "\"" });
    }

    const shebang_python = try std.fs.path.join(
        allocator,
        &.{ dest_path, venv.interpreter_relpath },
    );
    defer allocator.free(shebang_python);

    try std.fmt.format(main_py_writer,
        \\
        \\
        \\if __name__ == "__main__":
        \\    boot(
        \\        shebang_python="{[shebang_python]s}",
        \\        venv_bin_dir="{[venv_bin_dir]s}",
        \\        bin_path="{[bin_path]s}",
        \\        strip_pex_env={[strip_pex_env]s},
        \\        inject_env={{{[inject_env]s}}},
        \\        inject_args=[{[inject_args]s}],
        \\        entry_point={[entry_point]s},
        \\        script={[script]s},
        \\        hermetic_re_exec={[hermetic_re_exec]s},
        \\    )
        \\
    , .{
        .shebang_python = shebang_python,
        .venv_bin_dir = std.fs.path.dirname(venv.interpreter_relpath) orelse "",
        .bin_path = bin_path,
        .strip_pex_env = if (self.pex_info.strip_pex_env orelse false) "True" else "False",
        .inject_env = inject_env,
        .inject_args = inject_args,
        .entry_point = entry_point orelse "None",
        .script = script orelse "None",
        .hermetic_re_exec = if (self.pex_info.venv_hermetic_scripts) "True" else "False",
    });

    try main_py_fp.flush();

    if (native_os != .windows) {
        const metadata = try main_py.metadata();
        var permissions = metadata.permissions();
        permissions.inner.unixSet(.user, .{ .execute = true });
        permissions.inner.unixSet(.group, .{ .execute = true });
        permissions.inner.unixSet(.other, .{ .execute = true });
        try main_py.setPermissions(permissions);
    }
    main_py.close();

    work_dir.symLink("__main__.py", "pex", .{}) catch |err| {
        if (native_os != .windows) {
            return err;
        }
        try work_dir.copyFile("__main__.py", work_dir, "pex", .{});
    };

    return venv;
}
