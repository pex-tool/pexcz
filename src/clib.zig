const builtin = @import("builtin");
const std = @import("std");
const pexcz = @import("pexcz");

const EnvList = std.ArrayList([*:0]u8);

fn setupEnv(allocator: std.mem.Allocator, environ: [*:null]const ?[*c]const u8) !?EnvList {
    // N.B.: The environment is already set up correctly for Windows processes.
    if (builtin.target.os.tag == .windows) {
        return null;
    }

    var env_list: EnvList = try .initCapacity(allocator, std.mem.len(environ));
    errdefer env_list.deinit();

    var i: usize = 0;
    while (environ[i]) |entryZ| : (i += 1) {
        try env_list.append(@constCast(entryZ));
    }
    std.os.environ = env_list.items;
    return env_list;
}

const BootResult = enum(c_uint) { success = 0, env_setup_failure = 1, boot_failure = 2 };

export fn boot(
    python: [*c]const u8,
    pex: [*c]const u8,
    environ: [*:null]const ?[*c]const u8,
) BootResult {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*t| std.debug.print(
        "C boot({s}, {s}, ...) took {d:.3}µs\n",
        .{ python, pex, t.read() / 1_000 },
    );

    var alloc = pexcz.Allocator(.{ .safety = true, .verbose_log = true }).init();
    defer alloc.deinit();
    const allocator = alloc.allocator();

    const env_list = setupEnv(allocator, environ) catch |err| {
        std.debug.print(
            "Failed to set up environment to boot {[pex]s} using {[python]s}: {[err]}",
            .{ .pex = pex, .python = python, .err = err },
        );
        return .env_setup_failure;
    };
    defer if (env_list) |el| el.deinit();

    pexcz.bootPexZ(allocator, python, pex) catch |err| {
        std.debug.print(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
        return .boot_failure;
    };
    return .success;
}
