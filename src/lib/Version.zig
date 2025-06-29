const std = @import("std");

const string = @import("string.zig");

fn trim_leading_v(value: []const u8) []const u8 {
    return if (value.len > 0 and value[0] == 'v') value[1..] else value;
}

pub const Release = struct {
    segments: []const u16,
    wildcard: bool,

    fn major(self: Release) u16 {
        return self.segments[0];
    }

    fn minor(self: Release) u16 {
        return if (self.segments.len >= 2) self.segments[1] else 0;
    }

    fn patch(self: Release) u16 {
        return if (self.segments.len >= 3) self.segments[2] else 0;
    }

    fn eq(self: Release, other: Release) bool {
        const release_segments = @max(self.segments.len, other.segments.len);
        for (0..release_segments) |index| {
            if (self.wildcard and index >= self.segments.len) break;
            const my_segment = if (index < self.segments.len) self.segments[index] else 0;
            const other_segment = if (index < other.segments.len) other.segments[index] else 0;
            if (my_segment != other_segment) return false;
        }
        return true;
    }

    fn ne(self: Release, other: Release) bool {
        return !self.eq(other);
    }

    fn gte(self: Release, other: Release) bool {
        const segment_count = self.segments.len;
        const other_segment_count = other.segments.len;
        const release_segments = @max(segment_count, other_segment_count);
        for (0..release_segments) |index| {
            const my_segment = if (index < segment_count) self.segments[index] else 0;
            const other_segment = if (index < other_segment_count) other.segments[index] else 0;
            if (other_segment > my_segment) return true;
            if (other_segment < my_segment) return false;
        }
        return true;
    }

    fn gt(self: Release, other: Release) bool {
        return self.ne(other) and self.gte(other);
    }

    fn lt(self: Release, other: Release) bool {
        return !self.gte(other);
    }

    fn lte(self: Release, other: Release) bool {
        return !self.gt(other);
    }

    fn compatible(self: Release, other: Release) bool {
        const segment_count = self.segments.len;

        // TODO: XXX: Review: should this return an error?
        if (segment_count < 2) return false;

        const other_segment_count = other.segments.len;
        const leading_components = segment_count - 1;
        for (0..leading_components) |index| {
            const my_component = self.segments[index];
            const other_component = if (other_segment_count > index) other.segments[index] else 0;
            if (my_component != other_component) return false;
        }
        return self.gte(other);
    }
};

pub const PreRelease = union(enum) { alpha: u8, beta: u8, rc: u8 };

fn NonReleaseSegmentParser(comptime T: type, comptime prefixes: []const []const u8) type {
    const leaders = [_][]const u8{ "", ".", "-", "_" };
    comptime var all_prefixes: [prefixes.len * leaders.len][]const u8 = undefined;
    comptime var index = 0;

    inline for (prefixes) |prefix| {
        inline for (leaders) |leader| {
            all_prefixes[index] = leader ++ prefix;
            index += 1;
        }
    }

    return struct {
        fn parse(text: []const u8) !?std.meta.Tuple(&.{ T, usize }) {
            for (all_prefixes) |prefix| {
                if (!std.mem.startsWith(u8, text, prefix)) {
                    continue;
                }
                const start_index = prefix.len;
                var end_index = start_index;
                for (text[start_index..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        break;
                    } else {
                        end_index += 1;
                    }
                }
                const suffix = text[start_index..end_index];
                const segment_value = if (suffix.len == 0) 0 else try std.fmt.parseInt(
                    T,
                    suffix,
                    10,
                );
                return .{ segment_value, end_index };
            }
            return null;
        }
    };
}

const Alpha = NonReleaseSegmentParser(u8, &.{ "alpha", "a" });
const Beta = NonReleaseSegmentParser(u8, &.{ "beta", "b" });
const RC = NonReleaseSegmentParser(u8, &.{ "preview", "pre", "rc", "c" });
const Post = NonReleaseSegmentParser(u8, &.{ "post", "rev", "r" });
const Dev = NonReleaseSegmentParser(u8, &.{"dev"});

allocator: std.mem.Allocator,
raw: []const u8,
epoch: ?u8 = null,
release: Release,
pre_release: ?PreRelease = null,
post_release: ?u8 = null,
dev_release: ?u8 = null,
local_version: ?[]const u8 = null,

const Self = @This();

pub fn parse(
    allocator: std.mem.Allocator,
    value: []const u8,
    options: struct { wildcard_allowed: bool = false },
) !Self {
    const trimmed_value = trim_leading_v(string.trim_ascii_ws(value));
    const epoch, const rest = res: {
        if (std.mem.indexOfScalar(u8, trimmed_value, '!')) |index| {
            if (index == trimmed_value.len - 1) {
                return error.InvalidVersion;
            }
            break :res .{
                try std.fmt.parseInt(u8, trimmed_value[0..index], 10),
                trimmed_value[index + 1 ..],
            };
        } else {
            break :res .{ null, trimmed_value };
        }
    };

    var release_segments = try std.ArrayList(u16).initCapacity(allocator, 3);
    errdefer release_segments.deinit();

    var release_segment: [5]u8 = undefined;
    var release_digits: u8 = 0;
    var wildcard = false;

    var pre_release: ?PreRelease = null;
    var post_release: ?u8 = null;
    var dev_release: ?u8 = null;
    var local_version: ?[]const u8 = null;

    var index: usize = 0;
    while (index < rest.len) {
        const char = rest[index];
        if (!std.ascii.isDigit(char)) {
            if (pre_release == null and
                post_release == null and
                dev_release == null and
                local_version == null)
            {
                if (release_digits == 0) {
                    return error.InvalidVersion;
                }
                try release_segments.append(try std.fmt.parseInt(
                    u16,
                    release_segment[0..release_digits],
                    10,
                ));
                release_digits = 0;
            }

            if (char == '.') {
                if (index + 1 >= rest.len) {
                    return error.InvalidVersion;
                }
                const next_char = rest[index + 1];
                if (next_char == '*') {
                    if (!options.wildcard_allowed) {
                        return error.InvalidVersion;
                    }
                    wildcard = true;
                    index += 2;
                    break;
                } else if (std.ascii.isDigit(next_char)) {
                    index += 1;
                    continue;
                }
            } else if (char == '+') {
                if (index + 1 >= rest.len) {
                    return error.InvalidVersion;
                }
                const local_version_value = rest[index + 1 ..];
                for (local_version_value, 0..) |ch, idx| {
                    if (ch != '.' and !std.ascii.isAlphanumeric(ch)) {
                        return error.InvalidVersion;
                    }
                    if (ch == '.' and (idx == 0 or idx == local_version_value.len - 1)) {
                        return error.InvalidVersion;
                    }
                }
                local_version = local_version_value;
                index += local_version_value.len + 1;
                break;
            }

            if (index >= rest.len) break;
            const tail = rest[index..];
            if (try Alpha.parse(tail)) |result| {
                const alpha, const end_index = result;
                pre_release = .{ .alpha = alpha };
                index += end_index;
                continue;
            } else if (try Beta.parse(tail)) |result| {
                const beta, const end_index = result;
                pre_release = .{ .beta = beta };
                index += end_index;
                continue;
            } else if (try RC.parse(tail)) |result| {
                const rc, const end_index = result;
                pre_release = .{ .rc = rc };
                index += end_index;
                continue;
            } else if (try Post.parse(tail)) |result| {
                post_release, const end_index = result;
                index += end_index;
                continue;
            } else if (try Dev.parse(tail)) |result| {
                dev_release, const end_index = result;
                index += end_index;
                continue;
            } else return error.InvalidVersion;
        } else {
            if (release_digits >= release_segment.len) {
                return error.UnexpectedSelf;
            }
            release_segment[release_digits] = char;
            release_digits += 1;
        }
        index += 1;
    }
    if (release_digits > 0) {
        try release_segments.append(try std.fmt.parseInt(
            u16,
            release_segment[0..release_digits],
            10,
        ));
    }

    if (release_segments.items.len == 0) return error.InvalidVersion;
    if (index < rest.len) return error.InvalidVersion;

    return .{
        .allocator = allocator,
        .raw = trimmed_value,
        .epoch = epoch,
        .release = .{ .segments = try release_segments.toOwnedSlice(), .wildcard = wildcard },
        .pre_release = pre_release,
        .post_release = post_release,
        .dev_release = dev_release,
        .local_version = local_version,
    };
}

pub fn deinit(self: @This()) void {
    self.allocator.free(self.release.segments);
}

pub fn format(
    self: Self,
    fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    if (self.epoch) |epoch| {
        try std.fmt.format(writer, "{d}", .{epoch});
        try writer.writeByte('!');
    }
    for (self.release.segments, 0..) |release_segment, idx| {
        if (idx > 0) {
            try writer.writeByte('.');
        }
        try std.fmt.format(writer, "{d}", .{release_segment});
    }
    if (self.pre_release) |pre_release| {
        const label, const val = res: switch (pre_release) {
            .rc => |val| break :res .{ "rc", val },
            .beta => |val| break :res .{ "b", val },
            .alpha => |val| break :res .{ "a", val },
        };
        try writer.writeAll(label);
        try std.fmt.format(writer, "{d}", .{val});
    }
    if (self.post_release) |post_release| {
        try writer.writeByte('.');
        try writer.writeAll("post");
        try std.fmt.format(writer, "{d}", .{post_release});
    }
    if (self.dev_release) |dev_release| {
        try writer.writeByte('.');
        try writer.writeAll("dev");
        try std.fmt.format(writer, "{d}", .{dev_release});
    }
    if (self.local_version) |local_version| {
        try writer.writeByte('+');
        try writer.writeAll(local_version);
    }
}

pub fn major(self: Self) u16 {
    return self.release.major();
}

pub fn minor(self: Self) u16 {
    return self.release.minor();
}

pub fn patch(self: Self) u16 {
    return self.release.patch();
}

pub fn compatible(self: Self, other: Self) bool {
    const my_epoch: u8 = self.epoch orelse 0;
    const other_epoch: u8 = other.epoch orelse 0;
    if (other_epoch != my_epoch) return false;

    // TODO: Handle pre/post/dev/local
    return self.release.compatible(other.release);
}

pub fn lte(self: Self, other: Self) bool {
    return !self.gt(other);
}

pub fn gte(self: Self, other: Self) bool {
    const my_epoch: u8 = self.epoch orelse 0;
    const other_epoch: u8 = other.epoch orelse 0;
    if (other_epoch < my_epoch) return false;
    if (other_epoch > my_epoch) return true;

    // TODO: Handle pre/post/dev/local
    return self.release.gte(other.release);
}

pub fn lt(self: Self, other: Self) bool {
    return !self.gte(other);
}

pub fn gt(self: Self, other: Self) bool {
    return self.ne(other) and self.gte(other);
}

pub fn eq(self: Self, other: Self) bool {
    const my_epoch: u8 = self.epoch orelse 0;
    const other_epoch: u8 = other.epoch orelse 0;
    if (other_epoch != my_epoch) return false;

    // TODO: Handle pre/post/dev/local
    return self.release.eq(other.release);
}

pub fn ne(self: Self, other: Self) bool {
    return !self.eq(other);
}

test "alpha" {
    const expectAlpha = struct {
        fn expectAlpha(expected: u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .alpha = expected }, ver.pre_release);
        }
    }.expectAlpha;

    try expectAlpha(0, "3.9.2a");
    try expectAlpha(0, "3.9.2.a");
    try expectAlpha(0, "3.9.2-a");
    try expectAlpha(0, "3.9.2_a");

    try expectAlpha(0, "3.9.2alpha");
    try expectAlpha(0, "3.9.2.alpha");
    try expectAlpha(0, "3.9.2-alpha");
    try expectAlpha(0, "3.9.2_alpha");

    try expectAlpha(1, "3.9.2a1");
    try expectAlpha(12, "3.9.2alpha12");
}

test "beta" {
    const expectBeta = struct {
        fn expectBeta(expected: u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .beta = expected }, ver.pre_release);
        }
    }.expectBeta;

    try expectBeta(0, "3.9.2b");
    try expectBeta(0, "3.9.2.b");
    try expectBeta(0, "3.9.2-b");
    try expectBeta(0, "3.9.2_b");

    try expectBeta(0, "3.9.2beta");
    try expectBeta(0, "3.9.2.beta");
    try expectBeta(0, "3.9.2-beta");
    try expectBeta(0, "3.9.2_beta");

    try expectBeta(1, "3.9.2b1");
    try expectBeta(12, "3.9.2beta12");
}

test "rc" {
    const expectRc = struct {
        fn expectRc(expected: u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .rc = expected }, ver.pre_release);
        }
    }.expectRc;

    try expectRc(0, "3.9.2c");
    try expectRc(0, "3.9.2.c");
    try expectRc(0, "3.9.2-c");
    try expectRc(0, "3.9.2_c");

    try expectRc(0, "3.9.2rc");
    try expectRc(0, "3.9.2.rc");
    try expectRc(0, "3.9.2-rc");
    try expectRc(0, "3.9.2_rc");

    try expectRc(1, "3.9.2c1");
    try expectRc(2, "3.9.2pre2");
    try expectRc(3, "3.9.2preview3");
    try expectRc(12, "3.9.2rc12");
}

test "post" {
    const expectPost = struct {
        fn expectPost(expected: u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqual(expected, ver.post_release);
        }
    }.expectPost;

    try expectPost(0, "3.9.2r");
    try expectPost(0, "3.9.2.r");
    try expectPost(0, "3.9.2-r");
    try expectPost(0, "3.9.2_r");

    try expectPost(0, "3.9.2post");
    try expectPost(0, "3.9.2.post");
    try expectPost(0, "3.9.2-post");
    try expectPost(0, "3.9.2_post");

    try expectPost(1, "3.9.2r1");
    try expectPost(2, "3.9.2rev2");
    try expectPost(12, "3.9.2post12");
}

test "dev" {
    const expectDev = struct {
        fn expectDev(expected: u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqual(expected, ver.dev_release);
        }
    }.expectDev;

    try expectDev(0, "3.9.2dev");
    try expectDev(0, "3.9.2.dev");
    try expectDev(0, "3.9.2-dev");
    try expectDev(0, "3.9.2_dev");

    try expectDev(1, "3.9.2dev1");
    try expectDev(2, "3.9.2-dev2");
    try expectDev(12, "3.9.2.dev12");
}

test "local" {
    const expectLocal = struct {
        fn expectLocal(expected: []const u8, version: []const u8) !void {
            const ver = try Self.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expect(ver.local_version != null);
            try std.testing.expectEqualStrings(expected, ver.local_version.?);
        }
    }.expectLocal;

    try expectLocal("foo", "3.9.2+foo");
    try expectLocal("foo.bar", "3.9.2+foo.bar");
    try expectLocal("foo.123", "3.9.2+foo.123");
}

test "complex version" {
    const ver = try Self.parse(std.testing.allocator, "3.9rc1.post2.dev3+baz4", .{});
    defer ver.deinit();

    try std.testing.expectEqual(3, ver.major());
    try std.testing.expectEqual(9, ver.minor());
    try std.testing.expectEqual(0, ver.patch());
    try std.testing.expectEqualDeep(PreRelease{ .rc = 1 }, ver.pre_release);
    try std.testing.expectEqualDeep(2, ver.post_release);
    try std.testing.expectEqualDeep(3, ver.dev_release);
    try std.testing.expectEqualDeep("baz4", ver.local_version);
}

test "invalid versions" {
    const expectInvalidVersion = struct {
        fn expectInvalidVersion(text: []const u8) !void {
            const version = Self.parse(std.testing.allocator, text, .{}) catch |err| {
                try std.testing.expectEqual(error.InvalidVersion, err);
                return;
            };
            defer version.deinit();
            std.debug.print(
                "Expected {s} to parse as an invalid version, but got: {s}\n",
                .{ text, version },
            );
            try std.testing.expect(false);
        }
    }.expectInvalidVersion;

    try expectInvalidVersion("");
    try expectInvalidVersion("v");
    try expectInvalidVersion("0!");
    try expectInvalidVersion("1d");
    try expectInvalidVersion("1bob");
    try expectInvalidVersion("1+");
    try expectInvalidVersion("1+!");
    try expectInvalidVersion("1+#");
    try expectInvalidVersion("1+.local");
    try expectInvalidVersion("1+local.");
}

test "version format" {
    const expectFormat = struct {
        fn expectFormat(text: []const u8, expected_format: []const u8) !void {
            const version = try Self.parse(std.testing.allocator, text, .{});
            defer version.deinit();
            const actual_format = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{version});
            defer std.testing.allocator.free(actual_format);
            try std.testing.expectEqualStrings(expected_format, actual_format);
        }
    }.expectFormat;

    try expectFormat("1.2.3", "1.2.3");
    try expectFormat("v0!1.2.3", "0!1.2.3");
    try expectFormat("v1.2.3", "1.2.3");
    try expectFormat("1.2.3.rc0", "1.2.3rc0");
    try expectFormat("1.2.3.beta1", "1.2.3b1");
    try expectFormat("1.2.3-a2", "1.2.3a2");
    try expectFormat("1.2.3-r3", "1.2.3.post3");
    try expectFormat("1.2.3dev4", "1.2.3.dev4");
}
