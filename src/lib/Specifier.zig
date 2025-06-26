const std = @import("std");

fn trim_ws(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r");
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
        const trimmed_value = trim_ws(value);
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
        var remaining_index: usize = 0;
        var wildcard = false;
        // TODO: XXX: Need to handle transition from a release segment to pre | post | dev | local.
        for (rest, 0..) |char, index| {
            if (!std.ascii.isDigit(char)) {
                if (release_digits == 0) {
                    return error.InvalidVersion;
                }
                try release_segments.append(try std.fmt.parseInt(
                    u16,
                    release_segment[0..release_digits],
                    10,
                ));
                release_digits = 0;
                if (char == '.' and index + 1 < rest.len and rest[index + 1] == '*') {
                    if (!options.wildcard_allowed) {
                        return error.InvalidVersion;
                    }
                    wildcard = true;
                    break;
                }
            } else {
                if (release_digits >= release_segment.len) {
                    return error.UnexpectedVersion;
                }
                release_segment[release_digits] = char;
                release_digits += 1;
            }
            remaining_index += 1;
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
