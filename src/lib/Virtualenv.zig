const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Interpreter = @import("interpreter.zig").Interpreter;
const subprocess = @import("subprocess.zig");

pub const VIRTUALENV_PY = @embedFile("virtualenv.py");

const log = std.log.scoped(.virtualenv);

const SitePackagesRelpath = struct {
    value: []const u8,
    owned: bool,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.value);
        }
    }
};

allocator: std.mem.Allocator,
dir: std.fs.Dir,
interpreter_relpath: []const u8,
site_packages_relpath: SitePackagesRelpath,

const Self = @This();

fn createInterpreterRelpath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.path.join(
        allocator,
        res: {
            if (native_os == .windows) {
                break :res &.{ "Scripts", "python.exe" };
            } else {
                break :res &.{ "bin", "python" };
            }
        },
    );
}

fn createSitePackagesRelpath(
    allocator: std.mem.Allocator,
    interpreter: Interpreter,
) !SitePackagesRelpath {
    if (native_os == .windows) {
        return .{
            .value = try std.fs.path.join(allocator, &.{ "Lib", "site-packages" }),
            .owned = true,
        };
    }
    const python_version = try std.fmt.allocPrint(
        allocator,
        "{s}{d}.{d}",
        .{
            if (interpreter.marker_env.is_pypy()) "pypy" else "python",
            interpreter.version.major,
            interpreter.version.minor,
        },
    );
    defer allocator.free(python_version);
    if (interpreter.marker_env.is_pypy() and
        (interpreter.version.major == 2 or interpreter.version.minor < 8))
    {
        return .{ .value = "site-packages", .owned = false };
    } else {
        return .{
            .value = try std.fs.path.join(allocator, &.{ "lib", python_version, "site-packages" }),
            .owned = true,
        };
    }
}

pub fn load(allocator: std.mem.Allocator, venv_dir: std.fs.Dir) !Self {
    var pyvenv_cfg = try venv_dir.openFile("pyvenv.cfg", .{});
    defer pyvenv_cfg.close();

    var buffered_reader = std.io.bufferedReader(pyvenv_cfg.reader());
    var reader = buffered_reader.reader();
    var found_home = false;

    var interpreter_relpath: ?[]const u8 = null;
    errdefer if (interpreter_relpath) |path| allocator.free(path);

    var site_packages_relpath: ?SitePackagesRelpath = null;
    errdefer if (site_packages_relpath) |path| path.deinit(allocator);

    var buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const home_key = "home = ";
        const interpreter_relpath_key = "interpreter-relpath = ";
        const site_packages_relpath_key = "site-packages-relpath = ";
        if (std.mem.startsWith(u8, line, home_key)) {
            var home = try venv_dir.openDir(
                std.mem.trimRight(u8, line[home_key.len..line.len], "\r"),
                .{},
            );
            defer home.close();
            found_home = true;
        } else if (std.mem.startsWith(u8, line, interpreter_relpath_key)) {
            std.debug.assert(found_home);
            const path = std.mem.trimRight(
                u8,
                line[interpreter_relpath_key.len..line.len],
                "\r",
            );
            try venv_dir.access(path, .{});
            interpreter_relpath = try allocator.dupe(u8, path);
        } else if (std.mem.startsWith(u8, line, site_packages_relpath_key)) {
            std.debug.assert(found_home);
            const path = std.mem.trimRight(
                u8,
                line[site_packages_relpath_key.len..line.len],
                "\r",
            );
            try venv_dir.access(path, .{});
            site_packages_relpath = .{ .value = try allocator.dupe(u8, path), .owned = true };
        }
    }
    if (!found_home) {
        return error.InvalidPyvenvCfgFile;
    }

    if (interpreter_relpath == null) {
        interpreter_relpath = try Self.createInterpreterRelpath(allocator);
    }

    if (site_packages_relpath == null) {
        const interpreter_path = try venv_dir.realpathAlloc(allocator, interpreter_relpath.?);
        defer allocator.free(interpreter_path);

        const interpreter = try Interpreter.identify(allocator, interpreter_path);
        defer interpreter.deinit();

        site_packages_relpath = try Self.createSitePackagesRelpath(allocator, interpreter.value);
    }

    return .{
        .allocator = allocator,
        .dir = venv_dir,
        .interpreter_relpath = interpreter_relpath.?,
        .site_packages_relpath = site_packages_relpath.?,
    };
}

const CreateOptions = struct {
    include_pip: bool = false,
    include_system_site_packages: bool = false,
};

pub fn create(
    allocator: std.mem.Allocator,
    interpreter: Interpreter,
    dest_dir: std.fs.Dir,
    options: CreateOptions,
) !Self {
    const venv_python_relpath = try Self.createInterpreterRelpath(allocator);
    errdefer allocator.free(venv_python_relpath);

    const site_packages_relpath = try Self.createSitePackagesRelpath(allocator, interpreter);
    errdefer site_packages_relpath.deinit(allocator);

    if (interpreter.version.major < 3) {
        var virtualenv = try dest_dir.createFile("virtualenv.py", .{});
        errdefer virtualenv.close();

        var virtualenv_fp = std.io.bufferedWriter(virtualenv.writer());
        try virtualenv_fp.writer().writeAll(VIRTUALENV_PY);
        try virtualenv_fp.flush();
        virtualenv.close();

        const CheckCall = struct {
            pub fn printError() void {
                std.debug.print("Failed to create venv.\n", .{});
            }
        };
        try subprocess.run(
            allocator,
            &.{
                interpreter.path,
                "virtualenv.py",
                "--no-download",
                "--no-pip",
                "--no-setuptools",
                "--no-wheel",
                ".",
            },
            subprocess.CheckCall(CheckCall.printError),
            .{ .extra_child_run_args = .{ .cwd_dir = dest_dir } },
        );
    } else {
        if (std.fs.path.dirname(venv_python_relpath)) |venv_bin_dir| {
            try dest_dir.makePath(venv_bin_dir);
        }
        if (native_os == .windows) {
            try dest_dir.copyFile(interpreter.realpath, dest_dir, venv_python_relpath, .{});
        } else {
            try dest_dir.symLink(interpreter.realpath, venv_python_relpath, .{});
        }

        try dest_dir.makePath(site_packages_relpath.value);
    }

    const home_bin_dir = std.fs.path.dirname(interpreter.realpath) orelse {
        return error.UnparentedPythonError;
    };

    const pyvenv_cfg = try dest_dir.createFile("pyvenv.cfg", .{});
    defer pyvenv_cfg.close();

    const pyvenv_cfg_contents = try std.fmt.allocPrint(
        allocator,
        \\home = {s}
        \\include-system-site-packages = {s}
        \\interpreter-relpath = {s}
        \\site-packages-relpath = {s}
        \\
    ,
        .{
            home_bin_dir,
            if (options.include_system_site_packages) "true" else "false",
            venv_python_relpath,
            site_packages_relpath.value,
        },
    );
    defer allocator.free(pyvenv_cfg_contents);

    try pyvenv_cfg.writeAll(pyvenv_cfg_contents);

    if (options.include_pip) {
        const CheckCall = struct {
            pub fn printError() void {
                std.debug.print("Failed to install Pip in venv.\n", .{});
            }
        };

        if (native_os == .windows) {
            log.warn("About to try to run: {s} ...", .{venv_python_relpath});
            var dest_dir_iter = try dest_dir.walk(allocator);
            defer dest_dir_iter.deinit();
            log.warn("Dest venv dir contains:", .{});
            while (try dest_dir_iter.next()) |entry| {
                log.warn("    {s}", .{entry.path});
            }
        }

        // TODO: XXX: If no ensurepip module, dowload a pip .pyz and install that way.
        const args: []const []const u8 = if (interpreter.version.major < 3) &.{
            venv_python_relpath,
            "-m",
            "ensurepip",
        } else &.{ venv_python_relpath, "-m", "ensurepip", "--default-pip" };
        try subprocess.run(
            allocator,
            args,
            subprocess.CheckCall(CheckCall.printError),
            .{
                .extra_child_run_args = .{ .cwd_dir = dest_dir },
            },
        );
    }
    return .{
        .allocator = allocator,
        .dir = dest_dir,
        .interpreter_relpath = venv_python_relpath,
        .site_packages_relpath = site_packages_relpath,
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.interpreter_relpath);
    self.site_packages_relpath.deinit(self.allocator);
}
