const std = @import("std");

const PreRelease = Version.PreRelease;
const Release = Version.Release;
const Version = @import("Version.zig");
const string = @import("string.zig");

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
        const trimmed_clause = string.trim_ascii_ws(clause);
        if (trimmed_clause.len == 0) {
            return error.InvalidSpecifierClause;
        }
        switch (trimmed_clause[0]) {
            '=' => {
                if (trimmed_clause.len >= 3 and std.mem.eql(u8, "===", trimmed_clause[0..3])) {
                    const exact_version = string.trim_ascii_ws(trimmed_clause[3..]);
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
