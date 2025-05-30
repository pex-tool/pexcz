const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Interpreter = @import("interpreter.zig").Interpreter;
const subprocess = @import("subprocess.zig");

pub const VIRTUALENV_PY = @embedFile("virtualenv.py");

allocator: std.mem.Allocator,
dir: std.fs.Dir,
interpreter_relpath: []const u8,
site_packages_relpath: []const u8,

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

fn createSitePackagesRelpath(allocator: std.mem.Allocator, interpreter: Interpreter) ![]const u8 {
    if (native_os == .windows) {
        return try std.fs.path.join(allocator, &.{ "Lib", "site-packages" });
    }
    const python_version = try std.fmt.allocPrint(
        allocator,
        "python{d}.{d}",
        .{ interpreter.version.major, interpreter.version.minor },
    );
    defer allocator.free(python_version);
    return try std.fs.path.join(allocator, &.{ "lib", python_version, "site-packages" });
}

pub fn load(allocator: std.mem.Allocator, venv_dir: std.fs.Dir) !Self {
    var pyvenv_cfg = try venv_dir.openFile("pyvenv.cfg", .{});
    defer pyvenv_cfg.close();

    var buffered_reader = std.io.bufferedReader(pyvenv_cfg.reader());
    var reader = buffered_reader.reader();
    var found_home = false;

    var interpreter_relpath: ?[]const u8 = null;
    errdefer if (interpreter_relpath) |path| allocator.free(path);

    var site_packages_relpath: ?[]const u8 = null;
    errdefer if (site_packages_relpath) |path| allocator.free(path);

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
            site_packages_relpath = try allocator.dupe(u8, path);
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

pub fn create(
    allocator: std.mem.Allocator,
    interpreter: Interpreter,
    dest_dir: std.fs.Dir,
    include_pip: bool,
) !Self {
    // TODO: XXX: Use embedded VIRTUALENV_PY to create the venv for Python 2.
    if (interpreter.version.major < 3) {
        return error.TodoImplementPy2VenvCreate;
    }

    const home_bin_dir = std.fs.path.dirname(interpreter.realpath) orelse {
        return error.UnparentedPythonError;
    };

    const venv_python_relpath = try Self.createInterpreterRelpath(allocator);
    errdefer allocator.free(venv_python_relpath);

    if (std.fs.path.dirname(venv_python_relpath)) |venv_bin_dir| {
        try dest_dir.makePath(venv_bin_dir);
    }
    if (native_os == .windows) {
        try dest_dir.copyFile(interpreter.realpath, dest_dir, venv_python_relpath, .{});
    } else {
        try dest_dir.symLink(interpreter.realpath, venv_python_relpath, .{});
    }

    const site_packages_relpath = try Self.createSitePackagesRelpath(
        allocator,
        interpreter,
    );
    errdefer allocator.free(site_packages_relpath);
    try dest_dir.makePath(site_packages_relpath);

    const pyvenv_cfg = try dest_dir.createFile("pyvenv.cfg", .{});
    defer pyvenv_cfg.close();

    const pyvenv_cfg_contents = try std.fmt.allocPrint(
        allocator,
        \\home = {s}
        \\include-system-site-packages = false
        \\interpreter-relpath = {s}
        \\site-packages-relpath = {s}
        \\
    ,
        .{ home_bin_dir, venv_python_relpath, site_packages_relpath },
    );
    defer allocator.free(pyvenv_cfg_contents);

    try pyvenv_cfg.writeAll(pyvenv_cfg_contents);

    if (include_pip) {
        const CheckCall = struct {
            pub fn printError() void {
                std.debug.print("Failed to install Pip in venv.\n", .{});
            }
        };
        // TODO: XXX: If no ensurepip module, dowload a pip .pyz and install that way.
        try subprocess.run(
            allocator,
            &.{ venv_python_relpath, "-m", "ensurepip", "--default-pip" },
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
    self.allocator.free(self.site_packages_relpath);
}
