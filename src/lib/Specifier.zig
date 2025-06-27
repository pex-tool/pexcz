const std = @import("std");

fn trim_ws(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r");
}

fn trim_leading_v(value: []const u8) []const u8 {
    return if (value.len > 0 and value[0] == 'v') value[1..] else value;
}

const Release = struct {
    segments: []const u16,
    wildcard: bool,

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

const PreRelease = union(enum) { alpha: u8, beta: u8, rc: u8 };

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

const Version = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    epoch: ?u8 = null,
    release: Release,
    pre_release: ?PreRelease = null,
    post_release: ?u8 = null,
    dev_release: ?u8 = null,
    local_version: ?[]const u8 = null,

    fn parse(
        allocator: std.mem.Allocator,
        value: []const u8,
        options: struct { wildcard_allowed: bool = false },
    ) !Version {
        const trimmed_value = trim_leading_v(trim_ws(value));
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
                if (pre_release == null and post_release == null and dev_release == null and local_version == null) {
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
                        break;
                    } else if (std.ascii.isDigit(next_char)) {
                        index += 1;
                        continue;
                    }
                } else if (char == '+') {
                    if (index + 1 >= rest.len) {
                        return error.InvalidVersion;
                    }
                    local_version = rest[index + 1 ..];
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
                    const post, const end_index = result;
                    post_release = post;
                    index += end_index;
                    continue;
                } else if (try Dev.parse(tail)) |result| {
                    const dev, const end_index = result;
                    dev_release = dev;
                    index += end_index;
                    continue;
                }
            } else {
                if (release_digits >= release_segment.len) {
                    return error.UnexpectedVersion;
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

    fn deinit(self: @This()) void {
        self.allocator.free(self.release.segments);
    }

    fn compatible(self: Version, other: Version) bool {
        const my_epoch: u8 = self.epoch orelse 0;
        const other_epoch: u8 = other.epoch orelse 0;
        if (other_epoch != my_epoch) return false;

        // TODO: Handle pre/post/dev/local
        return self.release.compatible(other.release);
    }

    fn lte(self: Version, other: Version) bool {
        return !self.gt(other);
    }

    fn gte(self: Version, other: Version) bool {
        const my_epoch: u8 = self.epoch orelse 0;
        const other_epoch: u8 = other.epoch orelse 0;
        if (other_epoch < my_epoch) return false;
        if (other_epoch > my_epoch) return true;

        // TODO: Handle pre/post/dev/local
        return self.release.gte(other.release);
    }

    fn lt(self: Version, other: Version) bool {
        return !self.gte(other);
    }

    fn gt(self: Version, other: Version) bool {
        return self.ne(other) and self.gte(other);
    }

    fn eq(self: Version, other: Version) bool {
        const my_epoch: u8 = self.epoch orelse 0;
        const other_epoch: u8 = other.epoch orelse 0;
        if (other_epoch != my_epoch) return false;

        // TODO: Handle pre/post/dev/local
        return self.release.eq(other.release);
    }

    fn ne(self: Version, other: Version) bool {
        return !self.eq(other);
    }
};

const Clause = union(enum) {
    exact: []const u8,
    compatible: Version,
    lte: Version,
    gte: Version,
    lt: Version,
    gt: Version,
    eq: Version,
    ne: Version,
};

allocator: std.mem.Allocator,
raw: []const u8,
clauses: []Clause,

const Self = @This();

pub fn parse(allocator: std.mem.Allocator, value: []const u8) !Self {
    var clauses = std.ArrayList(Clause).init(allocator);
    var clause_iter = std.mem.splitScalar(u8, value, ',');
    while (clause_iter.next()) |clause| {
        const trimmed_clause = trim_ws(clause);
        if (trimmed_clause.len == 0) {
            return error.InvalidSpecifierClause;
        }
        switch (trimmed_clause[0]) {
            '=' => {
                if (trimmed_clause.len >= 3 and std.mem.eql(u8, "===", trimmed_clause[0..3])) {
                    const exact_version = trim_ws(trimmed_clause[3..]);
                    if (exact_version.len == 0) {
                        return error.InvalidVersion;
                    }
                    try clauses.append(.{ .exact = exact_version });
                } else if (trimmed_clause.len >= 2 and std.mem.eql(
                    u8,
                    "==",
                    trimmed_clause[0..2],
                )) {
                    try clauses.append(.{ .eq = try Version.parse(
                        allocator,
                        trimmed_clause[2..],
                        .{ .wildcard_allowed = true },
                    ) });
                } else {
                    return error.InvalidOperator;
                }
            },
            '!' => {
                if (trimmed_clause.len == 1 or trimmed_clause[1] != '=') {
                    return error.InvalidOperator;
                }
                try clauses.append(.{ .ne = try Version.parse(
                    allocator,
                    trimmed_clause[2..],
                    .{ .wildcard_allowed = true },
                ) });
            },
            '>' => {
                if (trimmed_clause.len > 1 and trimmed_clause[1] == '=') {
                    try clauses.append(.{ .gte = try Version.parse(
                        allocator,
                        trimmed_clause[2..],
                        .{},
                    ) });
                } else {
                    try clauses.append(.{ .gt = try Version.parse(
                        allocator,
                        trimmed_clause[1..],
                        .{},
                    ) });
                }
            },
            '<' => {
                if (trimmed_clause.len > 1 and trimmed_clause[1] == '=') {
                    try clauses.append(.{ .lte = try Version.parse(
                        allocator,
                        trimmed_clause[2..],
                        .{},
                    ) });
                } else {
                    try clauses.append(.{ .lt = try Version.parse(
                        allocator,
                        trimmed_clause[1..],
                        .{},
                    ) });
                }
            },
            '~' => {
                if (trimmed_clause.len == 1 or trimmed_clause[1] != '=') {
                    return error.InvalidOperator;
                }
                try clauses.append(.{ .compatible = try Version.parse(
                    allocator,
                    trimmed_clause[2..],
                    .{},
                ) });
            },
            else => return error.InvalidSpecifierClause,
        }
    }
    return Self{ .allocator = allocator, .raw = value, .clauses = try clauses.toOwnedSlice() };
}

pub fn deinit(self: Self) void {
    for (self.clauses) |clause| {
        switch (clause) {
            .compatible, .lte, .gte, .lt, .gt, .eq, .ne => |ver| ver.deinit(),
            else => {},
        }
    }
    self.allocator.free(self.clauses);
}

pub fn matches(self: Self, allocator: std.mem.Allocator, value: []const u8) !bool {
    const Parsed = struct {
        allocator: std.mem.Allocator,
        raw: []const u8,
        version: ?Version = null,

        fn parsedVersion(this: *@This()) !Version {
            return this.version orelse {
                const version = try Version.parse(this.allocator, this.raw, .{});
                this.version = version;
                return version;
            };
        }

        fn deinit(this: @This()) void {
            if (this.version) |ver| {
                ver.deinit();
            }
        }
    };
    var parsed = Parsed{ .allocator = allocator, .raw = value };
    defer parsed.deinit();

    for (self.clauses) |clause| {
        switch (clause) {
            .exact => |val| if (!std.mem.eql(u8, val, parsed.raw)) return false,
            .compatible => |ver| if (!ver.compatible(try parsed.parsedVersion())) return false,
            .lte => |ver| if (!ver.lte(try parsed.parsedVersion())) return false,
            .gte => |ver| if (!ver.gte(try parsed.parsedVersion())) return false,
            .lt => |ver| if (!ver.lt(try parsed.parsedVersion())) return false,
            .gt => |ver| if (!ver.gt(try parsed.parsedVersion())) return false,
            .eq => |ver| if (!ver.eq(try parsed.parsedVersion())) return false,
            .ne => |ver| if (!ver.ne(try parsed.parsedVersion())) return false,
        }
    }
    return true;
}

test "Arbitrary equality nominal" {
    const specifier = try Self.parse(std.testing.allocator, "===bob");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "bob"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "bill"));
}

test "Arbitrary equality whitespace" {
    const specifier = try Self.parse(std.testing.allocator, "===\tbob ");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "bob"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "bill"));
}

test "GTE" {
    try std.testing.expectEqual(
        error.InvalidVersion,
        Self.parse(std.testing.allocator, ">=3.9.*"),
    );

    const specifier = try Self.parse(std.testing.allocator, ">=3.9");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.23"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.13"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.13.5"));

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.8"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.8.20"));

    try std.testing.expect(try specifier.matches(std.testing.allocator, "0!3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "1!3.9"));

    const epoch_specifier = try Self.parse(std.testing.allocator, ">=1!3.9");
    defer epoch_specifier.deinit();

    try std.testing.expect(!try epoch_specifier.matches(std.testing.allocator, "0!3.9"));
    try std.testing.expect(try epoch_specifier.matches(std.testing.allocator, "1!3.9"));
    try std.testing.expect(try epoch_specifier.matches(std.testing.allocator, "2!3.9"));
}

test "GT" {
    try std.testing.expectEqual(error.InvalidVersion, Self.parse(std.testing.allocator, ">3.9.*"));

    const specifier = try Self.parse(std.testing.allocator, ">3.9");
    defer specifier.deinit();

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.23"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.13"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.13.5"));

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.8"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.8.20"));

    try std.testing.expect(try specifier.matches(std.testing.allocator, "0!3.9.1"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "1!3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "1!3.9.1"));

    const epoch_specifier = try Self.parse(std.testing.allocator, ">1!3.9");
    defer epoch_specifier.deinit();

    try std.testing.expect(!try epoch_specifier.matches(std.testing.allocator, "0!3.9"));
    try std.testing.expect(!try epoch_specifier.matches(std.testing.allocator, "1!3.9"));
    try std.testing.expect(try epoch_specifier.matches(std.testing.allocator, "1!3.9.1"));
    try std.testing.expect(try epoch_specifier.matches(std.testing.allocator, "2!3.9"));
    try std.testing.expect(try epoch_specifier.matches(std.testing.allocator, "2!3.9.1"));
}

test "LTE" {
    try std.testing.expectEqual(
        error.InvalidVersion,
        Self.parse(std.testing.allocator, "<=3.9.*"),
    );

    const specifier = try Self.parse(std.testing.allocator, "<=3.9");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.0"));
}

test "LT" {
    try std.testing.expectEqual(error.InvalidVersion, Self.parse(std.testing.allocator, "<3.9.*"));

    const specifier = try Self.parse(std.testing.allocator, "<3.9");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.0"));
}

test "Compatible" {
    try std.testing.expectEqual(
        error.InvalidVersion,
        Self.parse(std.testing.allocator, "~=3.9.*"),
    );

    const specifier = try Self.parse(std.testing.allocator, "~=3.9");
    defer specifier.deinit();

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "2"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "2.7"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "2.7.18"));

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.1"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.23"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.10"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.13"));

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "4"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "4.0"));
}

test "EQ" {
    const specifier = try Self.parse(std.testing.allocator, "==3.9");
    defer specifier.deinit();

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.0.0"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.1"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.8"));

    const wildcard_specifier = try Self.parse(std.testing.allocator, "==3.9.*");
    defer wildcard_specifier.deinit();

    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.9.0.0"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.9.1"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.9.23"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.8"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.10"));
}

test "NE" {
    const specifier = try Self.parse(std.testing.allocator, "!=3.9");
    defer specifier.deinit();

    try std.testing.expect(try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.0.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.1"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.8"));

    const wildcard_specifier = try Self.parse(std.testing.allocator, "!=3.9.*");
    defer wildcard_specifier.deinit();

    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.9.0"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.9.0.0"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.9.1"));
    try std.testing.expect(!try wildcard_specifier.matches(std.testing.allocator, "3.9.23"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.8"));
    try std.testing.expect(try wildcard_specifier.matches(std.testing.allocator, "3.10"));
}

test "Compound" {
    const specifier = try Self.parse(std.testing.allocator, "~=3.9.2,<3.9.20");
    defer specifier.deinit();

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.1"));

    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.2"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.2.0"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.3"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.19"));
    try std.testing.expect(try specifier.matches(std.testing.allocator, "3.9.19.99"));

    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.20"));
    try std.testing.expect(!try specifier.matches(std.testing.allocator, "3.9.20.0"));

    const subtractive_specifier = try Self.parse(
        std.testing.allocator,
        ">=2.7,!=3.0.*,!=3.1.*,!=3.2.*,!=3.3.*,!=3.4.*,<3.14",
    );
    defer subtractive_specifier.deinit();

    try std.testing.expect(try subtractive_specifier.matches(std.testing.allocator, "2.7.18"));
    try std.testing.expect(try subtractive_specifier.matches(std.testing.allocator, "3.5"));
    try std.testing.expect(try subtractive_specifier.matches(std.testing.allocator, "3.5.0"));
    try std.testing.expect(try subtractive_specifier.matches(std.testing.allocator, "3.13.5"));
    try std.testing.expect(try subtractive_specifier.matches(std.testing.allocator, "3.13.5"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.0"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.1.1"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.2.2"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.3.3"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.4"));
    try std.testing.expect(!try subtractive_specifier.matches(std.testing.allocator, "3.14"));
}

test "alpha" {
    const expect_alpha = struct {
        fn expect_alpha(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .alpha = expected }, ver.pre_release);
        }
    }.expect_alpha;

    try expect_alpha(0, "3.9.2a");
    try expect_alpha(0, "3.9.2.a");
    try expect_alpha(0, "3.9.2-a");
    try expect_alpha(0, "3.9.2_a");

    try expect_alpha(0, "3.9.2alpha");
    try expect_alpha(0, "3.9.2.alpha");
    try expect_alpha(0, "3.9.2-alpha");
    try expect_alpha(0, "3.9.2_alpha");

    try expect_alpha(1, "3.9.2a1");
    try expect_alpha(12, "3.9.2alpha12");
}

test "beta" {
    const expect_beta = struct {
        fn expect_beta(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .beta = expected }, ver.pre_release);
        }
    }.expect_beta;

    try expect_beta(0, "3.9.2b");
    try expect_beta(0, "3.9.2.b");
    try expect_beta(0, "3.9.2-b");
    try expect_beta(0, "3.9.2_b");

    try expect_beta(0, "3.9.2beta");
    try expect_beta(0, "3.9.2.beta");
    try expect_beta(0, "3.9.2-beta");
    try expect_beta(0, "3.9.2_beta");

    try expect_beta(1, "3.9.2b1");
    try expect_beta(12, "3.9.2beta12");
}

test "rc" {
    const expect_rc = struct {
        fn expect_rc(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqualDeep(PreRelease{ .rc = expected }, ver.pre_release);
        }
    }.expect_rc;

    try expect_rc(0, "3.9.2c");
    try expect_rc(0, "3.9.2.c");
    try expect_rc(0, "3.9.2-c");
    try expect_rc(0, "3.9.2_c");

    try expect_rc(0, "3.9.2rc");
    try expect_rc(0, "3.9.2.rc");
    try expect_rc(0, "3.9.2-rc");
    try expect_rc(0, "3.9.2_rc");

    try expect_rc(1, "3.9.2c1");
    try expect_rc(2, "3.9.2pre2");
    try expect_rc(3, "3.9.2preview3");
    try expect_rc(12, "3.9.2rc12");
}

test "post" {
    const expect_post = struct {
        fn expect_post(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqual(expected, ver.post_release);
        }
    }.expect_post;

    try expect_post(0, "3.9.2r");
    try expect_post(0, "3.9.2.r");
    try expect_post(0, "3.9.2-r");
    try expect_post(0, "3.9.2_r");

    try expect_post(0, "3.9.2post");
    try expect_post(0, "3.9.2.post");
    try expect_post(0, "3.9.2-post");
    try expect_post(0, "3.9.2_post");

    try expect_post(1, "3.9.2r1");
    try expect_post(2, "3.9.2rev2");
    try expect_post(12, "3.9.2post12");
}

test "dev" {
    const expect_dev = struct {
        fn expect_dev(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expectEqual(expected, ver.dev_release);
        }
    }.expect_dev;

    try expect_dev(0, "3.9.2dev");
    try expect_dev(0, "3.9.2.dev");
    try expect_dev(0, "3.9.2-dev");
    try expect_dev(0, "3.9.2_dev");

    try expect_dev(1, "3.9.2dev1");
    try expect_dev(2, "3.9.2-dev2");
    try expect_dev(12, "3.9.2.dev12");
}

test "local" {
    const expect_local = struct {
        fn expect_local(expected: []const u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
            defer ver.deinit();
            try std.testing.expect(ver.local_version != null);
            try std.testing.expectEqualStrings(expected, ver.local_version.?);
        }
    }.expect_local;

    try expect_local("foo", "3.9.2+foo");
    try expect_local("foo.bar", "3.9.2+foo.bar");
    try expect_local("foo.123", "3.9.2+foo.123");
}

test "complex version" {
    const ver = try Version.parse(std.testing.allocator, "3.9.2rc1.post2.dev3+baz4", .{});
    defer ver.deinit();

    try std.testing.expectEqualDeep(PreRelease{ .rc = 1 }, ver.pre_release);
    try std.testing.expectEqualDeep(2, ver.post_release);
    try std.testing.expectEqualDeep(3, ver.dev_release);
    try std.testing.expectEqualDeep("baz4", ver.local_version);
}
