const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const Interpreter = @import("interpreter.zig").Interpreter;
const PexInfo = @import("pex_info.zig").PexInfo;
const Tag = @import("pep-425.zig").Tag;
const subprocess = @import("subprocess.zig");

pub const VIRTUALENV_PY = @embedFile("virtualenv.py");

fn parse_wheel_tags(allocator: std.mem.Allocator, wheel_name: []const u8) ![]const Tag {
    var components = std.mem.splitBackwardsScalar(
        u8,
        wheel_name[0 .. wheel_name.len - ".whl".len],
        '-',
    );
    var tags = std.ArrayList(Tag).init(allocator);
    if (components.next()) |platforms| {
        var platforms_iter = std.mem.splitScalar(u8, platforms, '.');
        while (platforms_iter.next()) |platform| {
            if (components.next()) |abis| {
                var abis_iter = std.mem.splitScalar(u8, abis, '.');
                while (abis_iter.next()) |abi| {
                    if (components.next()) |pythons| {
                        var pythons_iter = std.mem.splitScalar(u8, pythons, '.');
                        while (pythons_iter.next()) |python| {
                            try tags.append(
                                .{ .python = python, .abi = abi, .platform = platform },
                            );
                        }
                    }
                }
            }
        }
    }
    if (tags.items.len == 0) {
        return error.InvalidWheelName;
    }
    return try tags.toOwnedSlice();
}

pub const VenvPex = struct {
    pub const main_py_relpath = "__main__.py";

    pex_path: []const u8,
    pex_info: PexInfo,

    const Self = @This();

    pub fn init(pex_path: [*:0]const u8, pex_info: PexInfo) !Self {
        return .{ .pex_path = std.mem.span(pex_path), .pex_info = pex_info };
    }

    pub fn install(
        self: Self,
        allocator: std.mem.Allocator,
        dest_path: []const u8,
        dest_dir: std.fs.Dir,
        interpreter: Interpreter,
        include_pip: bool,
    ) !Virtualenv {
        const venv = try Virtualenv.create(allocator, interpreter, dest_dir, include_pip);

        const TagContext = struct {
            pub fn hash(_: @This(), tag: Tag) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, tag, .Deep);
                return hasher.final();
            }

            pub fn eql(_: @This(), one: Tag, two: Tag) bool {
                return (std.mem.eql(u8, one.python, two.python) and
                    std.mem.eql(u8, one.abi, two.abi) and
                    std.mem.eql(u8, one.platform, two.platform));
            }
        };
        var tags_to_rank = std.HashMap(
            Tag,
            usize,
            TagContext,
            std.hash_map.default_max_load_percentage,
        ).init(allocator);
        defer tags_to_rank.deinit();

        for (interpreter.supported_tags, 0..) |tag, rank| {
            try tags_to_rank.put(tag, rank);
        }

        var dists = self.pex_info.distributions.map.iterator();
        while (dists.next()) |entry| {
            const wheel_tags = try parse_wheel_tags(allocator, entry.key_ptr.*);
            defer allocator.free(wheel_tags);

            for (wheel_tags) |wheel_tag| {
                if (tags_to_rank.get(wheel_tag)) |rank| {
                    std.debug.print(
                        "{d} {s} <- {s} matches {s}\n",
                        .{ rank, wheel_tag, entry.key_ptr.*, interpreter.path },
                    );
                }
            }
        }
        const main_py = try dest_dir.createFile(Self.main_py_relpath, .{});
        defer main_py.close();

        const main_py_body = (
            \\if __name__ == "__main__":
            \\    print("Hello Pexcz!")
            \\
        );
        if (native_os == .windows) {
            try main_py.writeAll(main_py_body);
        } else {
            const venv_interpreter_path = try std.fs.path.join(
                allocator,
                &.{ dest_path, venv.interpreter_relpath },
            );
            defer allocator.free(venv_interpreter_path);

            const main_py_contents = try std.fmt.allocPrint(
                allocator,
                \\#!{s}
                \\
                \\{s}
            ,
                .{ venv_interpreter_path, main_py_body },
            );
            defer allocator.free(main_py_contents);

            try main_py.writeAll(main_py_contents);

            const metadata = try main_py.metadata();
            var permissions = metadata.permissions();
            permissions.inner.unixSet(.user, .{ .execute = true });
            permissions.inner.unixSet(.group, .{ .execute = true });
            permissions.inner.unixSet(.other, .{ .execute = true });
            try main_py.setPermissions(permissions);
        }
        return venv;
    }
};

pub const Virtualenv = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    interpreter_relpath: []const u8,

    const Self = @This();

    fn create_interpreter_relpath(allocator: std.mem.Allocator) ![]const u8 {
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

    pub fn load(allocator: std.mem.Allocator, venv_dir: std.fs.Dir) !Self {
        var pyvenv_cfg = try venv_dir.openFile("pyvenv.cfg", .{});
        defer pyvenv_cfg.close();

        var buffered_reader = std.io.bufferedReader(pyvenv_cfg.reader());
        var reader = buffered_reader.reader();
        var found_home = false;
        var buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const home_key = "home = ";
            const interpreter_relpath_key = "interpreter-relpath = ";
            if (std.mem.startsWith(u8, line, home_key)) {
                var home = try venv_dir.openDir(
                    std.mem.trimRight(u8, line[home_key.len..line.len], "\r"),
                    .{},
                );
                defer home.close();
                found_home = true;
            } else if (std.mem.startsWith(u8, line, interpreter_relpath_key)) {
                std.debug.assert(found_home);
                const interpreter_relpath = std.mem.trimRight(
                    u8,
                    line[interpreter_relpath_key.len..line.len],
                    "\r",
                );
                try venv_dir.access(interpreter_relpath, .{});

                return .{
                    .allocator = allocator,
                    .dir = venv_dir,
                    .interpreter_relpath = try allocator.dupe(u8, interpreter_relpath),
                };
            }
        }
        if (!found_home) {
            return error.InvalidPyvenvCfgFile;
        }

        const interpreter_relpath = try Self.create_interpreter_relpath(allocator);
        errdefer allocator.free(interpreter_relpath);
        try venv_dir.access(interpreter_relpath, .{});

        return .{
            .allocator = allocator,
            .dir = venv_dir,
            .interpreter_relpath = interpreter_relpath,
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        interpreter: Interpreter,
        dest_dir: std.fs.Dir,
        include_pip: bool,
    ) !Self {
        const home_bin_dir = std.fs.path.dirname(interpreter.realpath) orelse {
            return error.UnparentedPythonError;
        };

        const venv_python_relpath = try Self.create_interpreter_relpath(allocator);
        errdefer allocator.free(venv_python_relpath);

        const pyvenv_cfg = try dest_dir.createFile("pyvenv.cfg", .{});
        defer pyvenv_cfg.close();

        const pyvenv_cfg_contents = try std.fmt.allocPrint(
            allocator,
            \\home = {s}
            \\include-system-site-packages = false
            \\interpreter-relpath = {s}
            \\
        ,
            .{ home_bin_dir, venv_python_relpath },
        );
        defer allocator.free(pyvenv_cfg_contents);

        try pyvenv_cfg.writeAll(pyvenv_cfg_contents);

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
