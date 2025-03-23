const native_os = @import("builtin").target.os.tag;
const std = @import("std");
const pexcz = @import("pexcz");

fn sliceZ(values: [*:null]?[*:0]const u8) [][*:0]u8 {
    var len: usize = 0;
    while (values[len] != null) : (len += 1) {}
    return @as([*][*:0]u8, @ptrCast(values))[0..len];
}

const BootResult = enum(c_int) {
    boot_error = 75,
    _,
};

export fn boot(
    python: [*:0]const u8,
    pex: [*:0]const u8,
    environ: [*:null]?[*:0]const u8,
    argv: [*:null]?[*:0]const u8,
) c_int {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*elpased| std.debug.print(
        "C boot({s}, {s}, ...) took {d:.3}µs\n",
        .{ python, pex, elpased.read() / 1_000 },
    );

    // N.B.: The environment and argv are already set up correctly for Windows processes.
    if (native_os != .windows) {
        std.os.environ = sliceZ(environ);
        std.os.argv = sliceZ(argv);
    }

    return pexcz.bootPexZ(python, pex) catch |err| {
        std.debug.print(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
        return @intFromEnum(BootResult.boot_error);
    };
}
