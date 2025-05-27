const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const std = @import("std");

const pexcz = @import("pexcz");

comptime {
    @export(
        if (native_os == .windows) &bootWindows else &bootPosix,
        .{ .name = "boot", .linkage = .strong },
    );
}

// TODO(John Sirois): Take a build option and use it when set instead of these defaults.
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

const log = std.log.scoped(.pexcz);

const BootResult = enum(c_int) {
    boot_error = 75,
    _,
};

fn bootWindows(
    python: [*:0]const u8,
    pex: [*:0]const u8,
) callconv(.c) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| log.info(
        "C boot({s}, {s}, ...) took {d:.3}µs",
        .{ python, pex, elpased.read() / 1_000 },
    );

    var alloc = pexcz.Allocator.init();
    defer {
        log.info("Bytes used: {d}", .{alloc.bytesUsed()});
        alloc.deinit();
    }

    return pexcz.bootPexZWindows(&alloc, python, pex) catch |err| {
        log.err(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
        return @intFromEnum(BootResult.boot_error);
    };
}

fn bootPosix(
    python: [*:0]const u8,
    pex: [*:0]const u8,
    argv: [*:null]?[*:0]const u8,
    envp: [*:null]?[*:0]const u8,
) callconv(.c) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| log.info(
        "C boot({s}, {s}, ...) took {d:.3}µs",
        .{ python, pex, elpased.read() / 1_000 },
    );

    var alloc = pexcz.Allocator.init();
    defer alloc.deinit();

    const environ = if (!builtin.link_libc) pexcz.Environ{
        .envp = envp,
    } else null;

    return pexcz.bootPexZPosix(&alloc, &timer, python, pex, environ, pexcz.sliceZ(argv)) catch |err| {
        log.err(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}",
            .{ .pex = pex, .python = python, .err = err },
        );
        return @intFromEnum(BootResult.boot_error);
    };
}
