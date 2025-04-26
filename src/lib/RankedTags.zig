const std = @import("std");

const Tag = @import("Tag.zig");

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
