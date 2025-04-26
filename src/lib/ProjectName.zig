const std = @import("std");

allocator: std.mem.Allocator,
value: []const u8,
raw: []const u8,

const Self = @This();

pub fn parse(allocator: std.mem.Allocator, name: []const u8) !Self {
    // See: https://peps.python.org/pep-0503/#normalized-names

    const normalized = try std.ascii.allocLowerString(allocator, name);
    errdefer allocator.free(normalized);

    std.mem.replaceScalar(u8, normalized, '_', '-');
    std.mem.replaceScalar(u8, normalized, '.', '-');
    const end = std.mem.collapseRepeatsLen(u8, normalized, '-');

    return .{
        .allocator = allocator,
        .value = try allocator.realloc(normalized, end),
        .raw = name,
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.value);
}

test "noop" {
    const project_name = try Self.parse(std.testing.allocator, "cowsay");
    defer project_name.deinit();

    try std.testing.expectEqualStrings("cowsay", project_name.raw);
    try std.testing.expectEqualStrings("cowsay", project_name.value);
}

test "lowercase" {
    const project_name = try Self.parse(std.testing.allocator, "PyYAML");
    defer project_name.deinit();

    try std.testing.expectEqualStrings("PyYAML", project_name.raw);
    try std.testing.expectEqualStrings("pyyaml", project_name.value);
}

test "special chars" {
    const project_name = try Self.parse(std.testing.allocator, "twitter.commons.lang");
    defer project_name.deinit();

    try std.testing.expectEqualStrings("twitter.commons.lang", project_name.raw);
    try std.testing.expectEqualStrings("twitter-commons-lang", project_name.value);
}

test "runs of special chars" {
    const project_name = try Self.parse(std.testing.allocator, "foo-_.bar_baz");
    defer project_name.deinit();

    try std.testing.expectEqualStrings("foo-_.bar_baz", project_name.raw);
    try std.testing.expectEqualStrings("foo-bar-baz", project_name.value);
}
