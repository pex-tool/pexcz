const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const std = @import("std");

const pexcz = @import("pexcz");

comptime {
    @export(
        if (native_os == .windows) &bootWindows else &bootPosix,
        .{ .name = "boot", .linkage = .strong },
    );
    @export(
        &mount,
        .{ .name = "mount", .linkage = .strong },
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
    argv: [*:null]?[*:0]const u8,
) callconv(.c) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| log.info(
        "C boot({s}, {s}, ...) took {d:.3}µs",
        .{ python, pex, elpased.read() / 1_000 },
    );

    var alloc = pexcz.Allocator.init();
    errdefer _ = alloc.deinit();

    const result = pexcz.bootPexZWindows(
        &alloc,
        &timer,
        python,
        pex,
        pexcz.sliceZ(argv),
    ) catch |err| res: {
        log.err(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}",
            .{ .pex = pex, .python = python, .err = err },
        );
        break :res @intFromEnum(BootResult.boot_error);
    };
    if (alloc.deinit() != .ok) {
        return @intFromEnum(BootResult.boot_error);
    } else {
        return result;
    }
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
    errdefer alloc.deinit();

    const environ = if (!builtin.link_libc) pexcz.Environ{
        .envp = envp,
    } else null;

    const result = pexcz.bootPexZPosix(
        &alloc,
        &timer,
        python,
        pex,
        environ,
        pexcz.sliceZ(argv),
    ) catch |err| res: {
        log.err(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}",
            .{ .pex = pex, .python = python, .err = err },
        );
        break :res @intFromEnum(BootResult.boot_error);
    };
    if (alloc.deinit() != .ok) {
        return @intFromEnum(BootResult.boot_error);
    } else {
        return result;
    }
}

fn mount(
    python: [*:0]const u8,
    pex: [*:0]const u8,
    sys_path_entry: [*:0]u8,
) callconv(.c) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| log.info(
        "C boot({s}, {s}, ...) took {d:.3}µs",
        .{ python, pex, elpased.read() / 1_000 },
    );

    var alloc = pexcz.Allocator.init();
    errdefer _ = alloc.deinit();

    pexcz.mount(&alloc, &timer, python, pex, sys_path_entry) catch |err| {
        log.err(
            "Failed to mount {[pex]s} using {[python]s}: {[err]}",
            .{ .pex = pex, .python = python, .err = err },
        );
        return 1;
    };
    return if (alloc.deinit() == .ok) 0 else 1;
}
