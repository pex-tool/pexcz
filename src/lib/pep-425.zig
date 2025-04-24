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

pub fn parse_wheel_tags(allocator: std.mem.Allocator, wheel_name: []const u8) ![]const Tag {
    var tags = std.ArrayList(Tag).init(allocator);
    defer tags.deinit();

    var components = std.mem.splitBackwardsScalar(
        u8,
        wheel_name[0 .. wheel_name.len - ".whl".len],
        '-',
    );
    if (components.next()) |platforms| {
        var platforms_iter = std.mem.splitScalar(u8, platforms, '.');
        while (platforms_iter.next()) |platform| {
            if (components.next()) |abis| {
                var abis_iter = std.mem.splitScalar(u8, abis, '.');
                while (abis_iter.next()) |abi| {
                    if (components.next()) |pythons| {
                        var pythons_iter = std.mem.splitScalar(u8, pythons, '.');
                        while (pythons_iter.next()) |python| {
                            try tags.append(
                                .{ .python = python, .abi = abi, .platform = platform },
                            );
                        }
                    }
                }
            }
        }
    }
    if (tags.items.len == 0) {
        return error.InvalidWheelName;
    }
    return try tags.toOwnedSlice();
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
