const std = @import("std");

const fs = @import("fs.zig");

const log = std.log.scoped(.layout);

const Layout = enum {
    zipapp,
    @"packed",
    loose,

    pub fn identify(pex: []const u8) !Layout {
        const cwd = std.fs.cwd();
        if (try fs.isDir(cwd, pex, .{})) {
            var pex_dir = try cwd.openDir(pex, .{});
            defer pex_dir.close();

            if (try fs.isDir(pex_dir, ".bootstrap", .{})) {
                return .loose;
            } else {
                return .@"packed";
            }
        } else {
            return .zipapp;
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

    try subprocess.checkCall(
        std.testing.allocator,
        &.{ python_exe, "-m", "pip", "install", "pex" },
        .{},
    );

    const pex = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "empty.pex" });
    errdefer std.testing.allocator.free(pex);

    try subprocess.checkCall(
        std.testing.allocator,
        &.{ python_exe, "-m", "pex", "--layout", @tagName(layout), "-o", pex },
        .{},
    );
    return pex;
}

test "identify zipapp" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .zipapp);
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.zipapp, Layout.identify(pex));
}

test "identify packed" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .@"packed");
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.@"packed", Layout.identify(pex));
}

test "identify loose" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pex = try createPex(tmp_dir, .loose);
    defer std.testing.allocator.free(pex);

    try std.testing.expectEqual(.loose, Layout.identify(pex));
}
