const std = @import("std");

pub const Tag = struct {
    python: []const u8,
    abi: []const u8,
    platform: []const u8,

    const Self = @This();

    pub fn format(
        self: Self,
        fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        try writer.writeAll(self.python);
        try writer.writeAll("-");
        try writer.writeAll(self.abi);
        try writer.writeAll("-");
        try writer.writeAll(self.platform);
    }

    pub fn jsonParse(
        _: std.mem.Allocator,
        source: *std.json.Scanner,
        _: std.json.ParseOptions,
    ) !Self {
        return switch (try source.next()) {
            .string => |value| {
                var iter = std.mem.splitScalar(u8, value, '-');
                if (iter.next()) |python| {
                    if (iter.next()) |abi| {
                        if (iter.next()) |platform| {
                            if (iter.next() == null) {
                                return .{ .python = python, .abi = abi, .platform = platform };
                            }
                        }
                    }
                }
                return error.SyntaxError;
            },
            else => return error.UnexpectedToken,
        };
    }
};
