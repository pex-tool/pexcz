const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const PexInfo = @import("pex_info.zig").PexInfo;
const Interpreter = @import("interpreter.zig").Interpreter;
const subprocess = @import("subprocess.zig");

pub const VIRTUALENV_PY = @embedFile("virtualenv.py");

pub const VenvPex = struct {
    pub const main_py_relpath = "__main__.py";

    allocator: std.mem.Allocator,
    interpreter: Interpreter,
    pex_path: []const u8,
    pex_info: PexInfo,
    venv_python_relpath: []const u8,
    include_pip: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, interpreter: Interpreter, pex_path: [*:0]const u8, pex_info: PexInfo, include_pip: bool) !Self {
        const venv_python_relpath = try std.fs.path.join(
            allocator,
            res: {
                if (native_os == .windows) {
                    break :res &.{ "Scripts", "python.exe" };
                } else {
                    break :res &.{ "bin", "python" };
                }
            },
        );
        return .{
            .allocator = allocator,
            .interpreter = interpreter,
            .pex_path = std.mem.span(pex_path),
            .pex_info = pex_info,
            .venv_python_relpath = venv_python_relpath,
            .include_pip = include_pip,
        };
    }

    pub fn install(self: Self, dest_dir: std.fs.Dir) !void {
        const venv = try Virtualenv.create(
            self.allocator,
            self.interpreter,
            dest_dir,
            self.include_pip,
        );
        defer venv.deinit();

        const main_py = try dest_dir.createFile(Self.main_py_relpath, .{});
        defer main_py.close();
        try main_py.writeAll(
            \\if __name__ == "__main__":
            \\    print("Hello Pexcz!")
        );
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.venv_python_relpath);
    }
};

pub const Virtualenv = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    interpreter_relpath: []const u8,

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        interpreter: Interpreter,
        dest_dir: std.fs.Dir,
        include_pip: bool,
    ) !Self {
        const home_bin_dir = std.fs.path.dirname(interpreter.realpath) orelse {
            return error.UnparentedPythonError;
        };

        const pyvenv_cfg = try dest_dir.createFile("pyvenv.cfg", .{});
        defer pyvenv_cfg.close();
        const pyvenv_cfg_contents = try std.fmt.allocPrint(
            allocator,
            \\home = {s}
            \\include-system-site-packages = false
            \\
        ,
            .{home_bin_dir},
        );
        defer allocator.free(pyvenv_cfg_contents);
        try pyvenv_cfg.writeAll(pyvenv_cfg_contents);

        const venv_python_relpath = try std.fs.path.join(
            allocator,
            res: {
                if (native_os == .windows) {
                    break :res &.{ "Scripts", "python.exe" };
                } else {
                    break :res &.{ "bin", "python" };
                }
            },
        );
        if (std.fs.path.dirname(venv_python_relpath)) |venv_bin_dir| {
            try dest_dir.makePath(venv_bin_dir);
        }
        if (native_os == .windows) {
            try dest_dir.copyFile(interpreter.realpath, dest_dir, venv_python_relpath, .{});
        } else {
            try dest_dir.symLink(interpreter.realpath, venv_python_relpath, .{});
        }
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
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.interpreter_relpath);
    }
};
