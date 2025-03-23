const std = @import("std");
const pexcz = @import("pexcz");

export fn boot(
    python: [*:0]const u8,
    pex: [*:0]const u8,
    environ: [*:null]const ?[*:0]const u8,
) void {
    // TODO(John Sirois): transition to noreturn instead of void.
    pexcz.bootPexZ(python, pex, environ) catch |err| {
        std.debug.print(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
    };
}
