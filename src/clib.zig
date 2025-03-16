const std = @import("std");
const pexcz = @import("pexcz");

export fn boot(python: [*c]const u8, pex: [*c]const u8) void {
    pexcz.bootPexZ(python, pex) catch |err| {
        std.debug.print(
            "Failed to boot {[pex]s} using {[python]s}: {[err]}\n",
            .{ .pex = pex, .python = python, .err = err },
        );
    };
}
