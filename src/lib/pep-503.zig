const std = @import("std");
const ProjectName = @import("pep-427.zig").ProjectName;

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
};

pub const WheelInfo = struct {
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
};

test "WheelInfo.parse nominal" {
    const wheel_info = try WheelInfo.parse(
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

test "WheelInfo.parse build tag" {
    const wheel_info = try WheelInfo.parse(
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

test "WheelInfo.parse invalid too few" {
    try std.testing.expectError(
        error.InvalidWheelName,
        WheelInfo.parse(std.testing.allocator, "cowsay-py2.py3-none-any.whl"),
    );
}

test "WheelInfo.parse invalid too many" {
    try std.testing.expectError(
        error.InvalidWheelName,
        WheelInfo.parse(std.testing.allocator, "cowsay-6.0-abcd1234-extra-py2.py3-none-any.whl"),
    );
}

pub const RankedTags = struct {
    const TagContext = struct {
        pub fn hash(_: @This(), tag: Tag) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, tag, .Deep);
            return hasher.final();
        }

        pub fn eql(_: @This(), one: Tag, two: Tag) bool {
            return (std.mem.eql(u8, one.python, two.python) and
                std.mem.eql(u8, one.abi, two.abi) and
                std.mem.eql(u8, one.platform, two.platform));
        }
    };

    const TagToRank = std.HashMap(
        Tag,
        usize,
        TagContext,
        std.hash_map.default_max_load_percentage,
    );

    tag_to_rank: TagToRank,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tags: []const Tag) !Self {
        var tag_to_rank = TagToRank.init(allocator);
        for (tags, 0..) |tag, index| {
            try tag_to_rank.put(tag, index);
        }
        return .{ .tag_to_rank = tag_to_rank };
    }

    pub fn rank(self: Self, tag: Tag) ?usize {
        return self.tag_to_rank.get(tag);
    }

    pub fn deinit(self: *Self) void {
        self.tag_to_rank.deinit();
    }
};
