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

test "alpha" {
    const expectAlpha = struct {
        fn expectAlpha(expected: u8, version: []const u8) !void {
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
            const ver = try Version.parse(std.testing.allocator, version, .{});
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
    const ver = try Version.parse(std.testing.allocator, "3.9rc1.post2.dev3+baz4", .{});
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
            const version = Version.parse(std.testing.allocator, text, .{}) catch |err| {
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
            const version = try Version.parse(std.testing.allocator, text, .{});
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
