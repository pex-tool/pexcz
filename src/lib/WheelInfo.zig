const std = @import("std");

const ProjectName = @import("ProjectName.zig");
const Tag = @import("Tag.zig");

pub fn parse(allocator: std.mem.Allocator, wheel_name: []const u8) !Self {
    if (!std.mem.endsWith(u8, wheel_name, ".whl")) {
        return error.InvalidWheelName;
    }
    const wheel_stem = wheel_name[0 .. wheel_name.len - ".whl".len];

    var leading_components = std.mem.splitScalar(u8, wheel_stem, '-');
    const project_name, const version = res: {
        if (leading_components.next()) |project_name| {
            if (leading_components.next()) |version| {
                break :res .{ project_name, version };
            }
        }
        return error.InvalidWheelName;
    };

    var tags = std.ArrayList(Tag).init(allocator);
    errdefer tags.deinit();

    var trailing_components = std.mem.splitBackwardsScalar(u8, leading_components.rest(), '-');
    var build_tag: ?[]const u8 = null;
    if (trailing_components.next()) |platforms| {
        var platforms_iter = std.mem.splitScalar(u8, platforms, '.');
        while (platforms_iter.next()) |platform| {
            if (trailing_components.next()) |abis| {
                var abis_iter = std.mem.splitScalar(u8, abis, '.');
                while (abis_iter.next()) |abi| {
                    if (trailing_components.next()) |pythons| {
                        var pythons_iter = std.mem.splitScalar(u8, pythons, '.');
                        while (pythons_iter.next()) |python| {
                            try tags.append(
                                .{ .python = python, .abi = abi, .platform = platform },
                            );
                        }
                        if (trailing_components.next()) |opt_build_tag| {
                            if (trailing_components.next() != null) {
                                return error.InvalidWheelName;
                            }
                            build_tag = opt_build_tag;
                        }
                    }
                }
            }
        }
    }
    if (tags.items.len == 0) {
        return error.InvalidWheelName;
    }

    return .{
        .allocator = allocator,
        .project_name = try ProjectName.parse(allocator, project_name),
        .version = version,
        .build_tag = build_tag,
        .tags = try tags.toOwnedSlice(),
    };
}

allocator: std.mem.Allocator,
project_name: ProjectName,
version: []const u8,
build_tag: ?[]const u8,
tags: []Tag,

const Self = @This();

pub fn deinit(self: Self) void {
    self.project_name.deinit();
    self.allocator.free(self.tags);
}

test "parse nominal" {
    const wheel_info = try Self.parse(
        std.testing.allocator,
        "cowsay-6.0-py2.py3-none-any.whl",
    );
    defer wheel_info.deinit();

    try std.testing.expectEqualDeep(
        ProjectName{ .allocator = std.testing.allocator, .value = "cowsay", .raw = "cowsay" },
        wheel_info.project_name,
    );
    try std.testing.expectEqualStrings("6.0", wheel_info.version);
    try std.testing.expect(wheel_info.build_tag == null);
    try std.testing.expectEqualDeep(
        &.{
            Tag{ .python = "py2", .abi = "none", .platform = "any" },
            Tag{ .python = "py3", .abi = "none", .platform = "any" },
        },
        wheel_info.tags,
    );
}

test "parse build tag" {
    const wheel_info = try Self.parse(
        std.testing.allocator,
        "cowsay-6.0-abcd1234-py3-none-any.whl",
    );
    defer wheel_info.deinit();

    try std.testing.expectEqualDeep(
        ProjectName{ .allocator = std.testing.allocator, .value = "cowsay", .raw = "cowsay" },
        wheel_info.project_name,
    );
    try std.testing.expectEqualStrings("6.0", wheel_info.version);
    try std.testing.expectEqualStrings("abcd1234", wheel_info.build_tag.?);
    try std.testing.expectEqualDeep(
        &.{
            Tag{ .python = "py3", .abi = "none", .platform = "any" },
        },
        wheel_info.tags,
    );
}

test "parse invalid too few" {
    try std.testing.expectError(
        error.InvalidWheelName,
        Self.parse(std.testing.allocator, "cowsay-py2.py3-none-any.whl"),
    );
}

test "parse invalid too many" {
    try std.testing.expectError(
        error.InvalidWheelName,
        Self.parse(std.testing.allocator, "cowsay-6.0-abcd1234-extra-py2.py3-none-any.whl"),
    );
}
