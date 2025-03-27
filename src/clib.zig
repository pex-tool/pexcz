const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const std = @import("std");

const pexcz = @import("pexcz");

const BootResult = enum(c_int) {
    boot_error = 75,
    _,
};

comptime {
    @export(
        if (native_os == .windows) &bootWindows else &bootPosix,
        .{ .name = "boot", .linkage = .strong },
    );
}

fn bootWindows(
    python: [*:0]const u8,
    pex: [*:0]const u8,
) callconv(.c) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| std.debug.print(
        "C boot({s}, {s}, ...) took {d:.3}µs\n",
        .{ python, pex, elpased.read() / 1_000 },
    );

    return pexcz.bootPexZWindows(python, pex) catch |err| {
        std.debug.print(
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
    defer if (timer) |*elpased| std.debug.print(
        "C boot({s}, {s}, ...) took {d:.3}µs\n",
        .{ python, pex, elpased.read() / 1_000 },
    );

    const environ = if (!builtin.link_libc) pexcz.Environ{
        .argv = argv,
        .envp = envp,
    } else null;
    return pexcz.bootPexZPosix(python, pex, environ) catch |err| {
        std.debug.print(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
        return @intFromEnum(BootResult.boot_error);
    };
}
