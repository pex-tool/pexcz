const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const PexInfo = @import("pex_info.zig").PexInfo;

pub const VIRTUALENV_PY = @embedFile("virtualenv.py");

pub const VenvPex = struct {
    pub const main_py_relpath = "__main__.py";

    allocator: std.mem.Allocator,
    python_exe_path: []const u8,
    pex_path: []const u8,
    pex_info: PexInfo,
    venv_python_relpath: []const u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        python_exe_path: [*:0]const u8,
        pex_path: [*:0]const u8,
        pex_info: PexInfo,
    ) !Self {
        const python_exe = try std.fs.cwd().openFileZ(python_exe_path, .{});
        defer python_exe.close();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const python_exe_realpath = try std.os.getFdPath(python_exe.handle, &buf);

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
            .python_exe_path = try allocator.dupe(u8, python_exe_realpath),
            .pex_path = std.mem.span(pex_path),
            .pex_info = pex_info,
            .venv_python_relpath = venv_python_relpath,
        };
    }

    pub fn install(self: Self, dest_dir: std.fs.Dir) !void {
        const home_bin_dir = std.fs.path.dirname(self.python_exe_path) orelse {
            return error.UnparentedPythonError;
        };

        const pyvenv_cfg = try dest_dir.createFile("pyvenv.cfg", .{});
        defer pyvenv_cfg.close();
        try pyvenv_cfg.writeAll(
            try std.fmt.allocPrint(
                self.allocator,
                \\home = {s}
                \\include-system-site-packages = false
                \\
            ,
                .{home_bin_dir},
            ),
        );

        if (std.fs.path.dirname(self.venv_python_relpath)) |venv_bin_dir| {
            try dest_dir.makePath(venv_bin_dir);
        }
        if (native_os == .windows) {
            try dest_dir.copyFile(self.python_exe_path, dest_dir, self.venv_python_relpath, .{});
        } else {
            try dest_dir.symLink(self.python_exe_path, self.venv_python_relpath, .{});
        }

        const main_py = try dest_dir.createFile(Self.main_py_relpath, .{});
        defer main_py.close();
        try main_py.writeAll(
            \\if __name__ == "__main__":
            \\    print("Hello Pexcz!")
        );
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.python_exe_path);
        self.allocator.free(self.venv_python_relpath);
    }
};
