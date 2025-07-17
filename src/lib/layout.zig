const std = @import("std");

const log = std.log.scoped(.layout);

const Layout = enum {
    zipapp,
    @"packed",
    loose,

    pub fn identify(
        allocator: std.mem.Allocator,
        pex: []const u8,
        options: struct { follow_symlinks: bool = true },
    ) !Layout {
        const stat = try std.fs.cwd().statFile(pex);
        switch (stat.kind) {
            .directory => {
                const pex_dir = try std.fs.cwd().openDir(pex, .{});
                const bootstrap_stat = try pex_dir.statFile(".bootstrap");
                if (bootstrap_stat.kind == .file) {
                    return .@"packed";
                } else {
                    return .loose;
                }
            },
            .sym_link => {
                if (options.follow_symlinks) {
                    const realpath = try std.fs.cwd().realpathAlloc(allocator, pex);
                    defer allocator.free(realpath);
                    return try identify(allocator, realpath, .{ .follow_symlinks = false });
                } else {
                    log.err("Cannot identify {s} as a PEX in any known layout.", .{pex});
                    return error.NotAPex;
                }
            },
            .file => return .zipapp,
            else => {
                log.err("Cannot identify {s} as a PEX in any known layout.", .{pex});
                return error.NotAPex;
            },
        }
    }
};

fn createPex(tmp_dir: std.testing.TmpDir, layout: Layout) ![]const u8 {
    const Interpreter = @import("Interpreter.zig");
    const Virtualenv = @import("Virtualenv.zig");
    const subprocess = @import("subprocess.zig");

    const interpreter = try struct {
        fn findInterpreter() !std.json.Parsed(Interpreter) {
            var interpreter_iter = try Interpreter.Iter.fromSearchPath(std.testing.allocator, .{});
            defer interpreter_iter.deinit();

            while (interpreter_iter.next()) |candidate| {
                if (candidate.value.has_ensurepip) {
                    return candidate;
                } else {
                    candidate.deinit();
                }
            }
            return error.InterpreterNotFound;
        }
    }.findInterpreter();
    defer interpreter.deinit();

    const tmp_dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_dir_path);

    const venv = try Virtualenv.create(
        std.testing.allocator,
        interpreter.value,
        tmp_dir_path,
        tmp_dir.dir,
        .{ .include_pip = true },
    );
    defer venv.deinit();

    const python_exe = try std.fs.path.join(
        std.testing.allocator,
        &.{ venv.path, venv.interpreter_relpath },
    );
    defer std.testing.allocator.free(python_exe);

    const CheckCall = struct {
        pub fn printError(msg: []const u8) void {
            std.debug.print("Failed to {s}.\n", .{msg});
        }
    };
    try subprocess.run(
        std.testing.allocator,
        &.{ python_exe, "-m", "pip", "install", "pex" },
        subprocess.CheckCall(CheckCall.printError),
        .{ .print_error_args = "install Pex" },
    );

    const pex = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "empty.pex" });
    errdefer std.testing.allocator.free(pex);

    try subprocess.run(
        std.testing.allocator,
        &.{ python_exe, "-m", "pex", "--layout", @tagName(layout), "-o", pex },
        subprocess.CheckCall(CheckCall.printError),
        .{ .print_error_args = "Create PEX" },
    );
    return pex;
}

test "identify zipapp" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .zipapp);
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.zipapp, Layout.identify(std.testing.allocator, pex, .{}));
}

test "identify packed" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .@"packed");
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.@"packed", Layout.identify(std.testing.allocator, pex, .{}));
}

test "identify loose" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .loose);
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.loose, Layout.identify(std.testing.allocator, pex, .{}));
}
