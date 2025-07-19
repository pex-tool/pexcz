const std = @import("std");

python: []const u8,
abi: []const u8,
platform: []const u8,

const Self = @This();

pub fn eql(self: Self, other: Self) bool {
    inline for (std.meta.fields(Self)) |field_info| {
        if (field_info.type != []const u8) {
            @compileError(
                "The eql method needs to be adjusted to take account of Tag struct changes.",
            );
        }
        const field_name = field_info.name;
        if (!std.mem.eql(u8, @field(self, field_name), @field(other, field_name))) return false;
    }
    return true;
}

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
    allocator: std.mem.Allocator,
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
                            return .{
                                .python = try allocator.dupe(u8, python),
                                .abi = try allocator.dupe(u8, abi),
                                .platform = try allocator.dupe(u8, platform),
                            };
                        }
                    }
                }
            }
            return error.SyntaxError;
        },
        else => return error.UnexpectedToken,
    };
}

test "eql" {
    const first = Self{ .python = "", .abi = "", .platform = ""};
    try std.testing.expect(std.meta.eql(first, first));
    try std.testing.expect(first.eql(first));

    const second = Self{ .python = "", .abi = "", .platform = ""};
    try std.testing.expect(std.meta.eql(first, second));
    try std.testing.expect(first.eql(second));

    const python = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(python);

    const third = Self{ .python = python, .abi = "", .platform = ""};
    try std.testing.expect(!std.meta.eql(first, third));
    try std.testing.expect(first.eql(third));
}