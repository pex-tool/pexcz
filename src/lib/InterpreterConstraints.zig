const builtin = @import("builtin");
const std = @import("std");
const zeit = @import("zeit");

const Interpreter = @import("interpreter.zig").Interpreter;
const Release = Version.Release;
const PreRelease = Version.PreRelease;
const Specifier = @import("Specifier.zig");
const Version = @import("Version.zig");
const string = @import("string.zig");

const log = std.log.scoped(.ics);

const PythonImplementation = enum { CPython, PyPy };

const InterpreterConstraint = struct {
    impl: ?PythonImplementation,
    specifier: Specifier,

    fn parse(allocator: std.mem.Allocator, constraint: []const u8) !InterpreterConstraint {
        const trimmed = string.trim_ascii_ws(constraint);
        var index: usize = 0;
        while (index < trimmed.len) {
            switch (trimmed[index]) {
                '!', '=', '<', '>', '~' => break,
                else => |c| if (std.ascii.isWhitespace(c)) {
                    break;
                } else {
                    index += 1;
                },
            }
        }
        const impl: ?PythonImplementation = res: {
            if (index == 0) {
                break :res null;
            } else if (std.meta.stringToEnum(PythonImplementation, trimmed[0..index])) |impl| {
                break :res impl;
            } else {
                return error.InvalidPythonImpl;
            }
        };
        const specifier = try Specifier.parse(allocator, constraint[index..]);
        for (specifier.clauses) |clause| {
            switch (clause) {
                .exact => return error.InvalidOperator,
                else => {},
            }
        }
        return .{ .impl = impl, .specifier = specifier };
    }

    fn deinit(self: InterpreterConstraint) void {
        self.specifier.deinit();
    }

    fn release_matches(self: InterpreterConstraint, release: Release) bool {
        return self.specifier.matches(.{ .release = release });
    }

    pub fn matches(self: InterpreterConstraint, interp: Interpreter) bool {
        if (self.impl) |impl| {
            switch (impl) {
                .CPython => if (!std.mem.eql(
                    u8,
                    "CPython",
                    interp.marker_env.platform_python_implementation,
                )) {
                    return false;
                },
                .PyPy => if (!std.mem.eql(
                    u8,
                    "PyPy",
                    interp.marker_env.platform_python_implementation,
                )) {
                    return false;
                },
            }
        }

        const release: Release = .{
            .major = interp.version.major,
            .minor = interp.version.minor,
            .patch = interp.version.micro,
        };

        const pre_release: ?PreRelease = res: {
            // C.F.: https://docs.python.org/3/library/sys.html#sys.version_info
            if (std.mem.eql(u8, "alpha", interp.version.releaselevel)) {
                break :res .{ .alpha = interp.version.serial };
            } else if (std.mem.eql(u8, "beta", interp.version.releaselevel)) {
                break :res .{ .beta = interp.version.serial };
            } else if (std.mem.eql(u8, "candidate", interp.version.releaselevel)) {
                break :res .{ .rc = interp.version.serial };
            } else {
                if (!std.mem.eql(u8, "final", interp.version.releaselevel)) {
                    log.warn("Unrecognized interpreter release level: {s}{d}. " ++
                        "Considering this a final release of {d}.{d}.{d}", .{
                        interp.version.releaselevel,
                        interp.version.serial,
                        interp.version.major,
                        interp.version.minor,
                        interp.version.micro,
                    });
                }
                break :res null;
            }
        };

        return self.specifier.matches(.{ .release = release, .pre_release = pre_release });
    }
};

const Self = @This();

allocator: std.mem.Allocator,
constraints: []InterpreterConstraint,

pub fn parse(allocator: std.mem.Allocator, interpreter_constraints: []const []const u8) !Self {
    var constraints = try std.ArrayList(InterpreterConstraint).initCapacity(
        allocator,
        interpreter_constraints.len,
    );
    errdefer constraints.deinit();
    for (interpreter_constraints) |interpreter_constraint| {
        try constraints.append(try InterpreterConstraint.parse(allocator, interpreter_constraint));
    }
    return .{ .allocator = allocator, .constraints = try constraints.toOwnedSlice() };
}

pub fn deinit(self: Self) void {
    for (self.constraints) |constraint| {
        constraint.deinit();
    }
    self.allocator.free(self.constraints);
}

pub fn matches(self: Self, interp: Interpreter) bool {
    if (self.constraints.len == 0) return true;
    for (self.constraints) |constraint| {
        if (constraint.matches(interp)) return true;
    }
    return false;
}

pub const PythonVersion = struct {
    major: u8,
    minor: u8,
    impl: ?PythonImplementation = null,
};

// N.B.: This assumes there will never be a Python 4.
pub const CompatibleVersionsIter = struct {
    constraints: []InterpreterConstraint,
    max_minor: u8,
    release: Release = .{ .major = 2, .minor = 7 },

    fn incrementVersion(self: *CompatibleVersionsIter) void {
        if (self.release.major == 2) {
            self.release.major = 3;
            self.release.minor = 5;
        } else {
            self.release.minor.? += 1;
        }
    }

    pub fn next(self: *CompatibleVersionsIter) ?PythonVersion {
        while (self.release.major != 3 or self.release.minor.? <= self.max_minor) {
            defer self.incrementVersion();
            for (self.constraints) |constraint| {
                if (constraint.release_matches(self.release)) {
                    return PythonVersion{
                        .major = @intCast(self.release.major),
                        .minor = self.release.minor.?,
                        .impl = constraint.impl,
                    };
                }
            }
        }
        return null;
    }
};

fn maxMinor() u8 {
    const static = struct {
        var max_minor: ?u8 = null;
    };
    return static.max_minor orelse {
        const current_production_release_minor: u8 = blk: {
            // Calibration point: 3.14.0 release will be in 10 / 2025 and there are yearly releases.
            const now = zeit.instant(.{ .source = .now }) catch {
                // N.B.: There are never errors when the source is not a string that needs to be
                // parsed.
                unreachable;
            };
            const time = now.time();
            // TODO(John Sirois): XXX: This goes wrong after 2266.
            const fall_release: u8 = @intCast(14 + @max(0, time.year - 2025));
            if (@intFromEnum(time.month) >= @intFromEnum(zeit.Month.oct)) {
                break :blk fall_release;
            } else {
                break :blk fall_release - 1;
            }
        };

        // N.B.: The +1 accounts for dev / alpha / beta / rc of the next Python release being
        // installed.
        const value = current_production_release_minor + 1;
        static.max_minor = value;
        return value;
    };
}

pub fn compatible_versions_iter(
    self: Self,
    options: struct { max: ?union(enum) { minor: u8, years_ahead: u8 } = null },
) CompatibleVersionsIter {
    const max_minor = res: {
        if (options.max) |max| {
            switch (max) {
                .minor => |val| break :res val,
                .years_ahead => |val| break :res maxMinor() + val,
            }
        } else {
            break :res maxMinor();
        }
    };
    return .{ .constraints = self.constraints, .max_minor = max_minor };
}

fn interpreter(
    allocator: std.mem.Allocator,
    spec: []const u8,
    options: struct { install: bool = true },
) !std.json.Parsed(Interpreter) {
    const subprocess = @import("subprocess.zig");
    const CheckFind = struct {
        python_spec: []const u8,
        install: bool,
        pub fn printError(self: @This()) void {
            std.debug.print(
                "Failed to find interpreter for {s}{s}\n",
                .{ self.python_spec, if (self.install) "; attempting install..." else "." },
            );
        }
    };
    const output = subprocess.run(
        allocator,
        &.{ "uv", "python", "find", spec },
        subprocess.CheckOutput(CheckFind.printError),
        .{
            .extra_child_run_args = .{ .max_output_bytes = std.fs.max_path_bytes + 2 },
            .print_error_args = .{ .python_spec = spec, .install = options.install },
        },
    ) catch |err| {
        if (options.install) {
            const CheckInstall = struct {
                pub fn printError(python_spec: []const u8) void {
                    std.debug.print("Failed to install interpreter for {s}.\n", .{python_spec});
                }
            };
            try subprocess.run(
                allocator,
                &.{ "uv", "python", "install", spec },
                subprocess.CheckCall(CheckInstall.printError),
                .{ .print_error_args = spec },
            );
            return interpreter(allocator, spec, .{ .install = false });
        } else return err;
    };
    defer allocator.free(output);
    return Interpreter.identify(allocator, std.mem.trim(u8, output, " \t\r\n"));
}

const windows_arm = builtin.os.tag == .windows and builtin.cpu.arch == .aarch64;

const Pythons = struct {
    cpython38: std.json.Parsed(Interpreter),
    cpython39: std.json.Parsed(Interpreter),
    cpython312: std.json.Parsed(Interpreter),
    pypy38: ?std.json.Parsed(Interpreter),
    pypy310: ?std.json.Parsed(Interpreter),
    pypy311: ?std.json.Parsed(Interpreter),

    fn init(allocator: std.mem.Allocator) !Pythons {
        const cpython38 = try interpreter(allocator, "3.8", .{});
        errdefer cpython38.deinit();

        const cpython39 = try interpreter(allocator, "3.9", .{});
        errdefer cpython39.deinit();

        const cpython312 = try interpreter(allocator, "3.12", .{});
        errdefer cpython312.deinit();

        var pypy38: ?std.json.Parsed(Interpreter) = null;
        if (pypy38) |interp| interp.deinit();

        var pypy310: ?std.json.Parsed(Interpreter) = null;
        if (pypy310) |interp| interp.deinit();

        var pypy311: ?std.json.Parsed(Interpreter) = null;
        if (pypy311) |interp| interp.deinit();

        // N.B.: There are currently no PyPy builds for Windows ARM.
        if (!windows_arm) {
            pypy38 = try interpreter(allocator, "pypy3.8", .{});
            pypy310 = try interpreter(allocator, "pypy3.10", .{});
            pypy311 = try interpreter(allocator, "pypy3.11", .{});
        }

        return .{
            .cpython38 = cpython38,
            .cpython39 = cpython39,
            .cpython312 = cpython312,
            .pypy38 = pypy38,
            .pypy310 = pypy310,
            .pypy311 = pypy311,
        };
    }

    fn deinit(self: Pythons) void {
        self.cpython38.deinit();
        self.cpython39.deinit();
        self.cpython312.deinit();
        if (self.pypy38) |interp| interp.deinit();
        if (self.pypy310) |interp| interp.deinit();
        if (self.pypy311) |interp| interp.deinit();
    }
};

test "no impl" {
    const ics = try Self.parse(std.testing.allocator, &.{">=3.9"});
    defer ics.deinit();

    try std.testing.expectEqual(1, ics.constraints.len);
    try std.testing.expect(ics.constraints[0].impl == null);

    const expected_specifier = try Specifier.parse(std.testing.allocator, ">=3.9");
    defer expected_specifier.deinit();
    try std.testing.expectEqualDeep(expected_specifier, ics.constraints[0].specifier);

    const pythons = try Pythons.init(std.testing.allocator);
    defer pythons.deinit();

    try std.testing.expect(!ics.matches(pythons.cpython38.value));
    try std.testing.expect(ics.matches(pythons.cpython39.value));
    try std.testing.expect(ics.matches(pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!ics.matches(pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(ics.matches(pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(ics.matches(pypy311.value));
    }
}

test "CPython" {
    const ics = try Self.parse(std.testing.allocator, &.{"CPython >=3.11"});
    defer ics.deinit();

    try std.testing.expectEqual(1, ics.constraints.len);
    try std.testing.expectEqual(PythonImplementation.CPython, ics.constraints[0].impl);

    const expected_specifier = try Specifier.parse(std.testing.allocator, " >=3.11");
    defer expected_specifier.deinit();
    try std.testing.expectEqualDeep(expected_specifier, ics.constraints[0].specifier);

    const pythons = try Pythons.init(std.testing.allocator);
    defer pythons.deinit();

    try std.testing.expect(!ics.matches(pythons.cpython38.value));
    try std.testing.expect(!ics.matches(pythons.cpython39.value));
    try std.testing.expect(ics.matches(pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!ics.matches(pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!ics.matches(pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(!ics.matches(pypy311.value));
    }
}

test "PyPy" {
    const ics = try Self.parse(std.testing.allocator, &.{"PyPy==3.11.*"});
    defer ics.deinit();

    try std.testing.expectEqual(1, ics.constraints.len);
    try std.testing.expectEqual(PythonImplementation.PyPy, ics.constraints[0].impl);

    const expected_specifier = try Specifier.parse(std.testing.allocator, "==3.11.*");
    defer expected_specifier.deinit();
    try std.testing.expectEqualDeep(expected_specifier, ics.constraints[0].specifier);

    const pythons = try Pythons.init(std.testing.allocator);
    defer pythons.deinit();

    try std.testing.expect(!ics.matches(pythons.cpython38.value));
    try std.testing.expect(!ics.matches(pythons.cpython39.value));
    try std.testing.expect(!ics.matches(pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!ics.matches(pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!ics.matches(pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(ics.matches(pypy311.value));
    }
}

test "ORed constraints" {
    const ics = try Self.parse(std.testing.allocator, &.{ "PyPy==3.11.*", "==3.8.*" });
    defer ics.deinit();

    try std.testing.expectEqualDeep(2, ics.constraints.len);
    try std.testing.expectEqual(PythonImplementation.PyPy, ics.constraints[0].impl);
    try std.testing.expectEqual(null, ics.constraints[1].impl);

    const expected_specifier1 = try Specifier.parse(std.testing.allocator, "==3.11.*");
    defer expected_specifier1.deinit();
    try std.testing.expectEqualDeep(expected_specifier1, ics.constraints[0].specifier);

    const expected_specifier2 = try Specifier.parse(std.testing.allocator, "==3.8.*");
    defer expected_specifier2.deinit();
    try std.testing.expectEqualDeep(expected_specifier2, ics.constraints[1].specifier);

    const pythons = try Pythons.init(std.testing.allocator);
    defer pythons.deinit();

    try std.testing.expect(ics.matches(pythons.cpython38.value));
    try std.testing.expect(!ics.matches(pythons.cpython39.value));
    try std.testing.expect(!ics.matches(pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(ics.matches(pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!ics.matches(pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(ics.matches(pypy311.value));
    }
}

test "Compatible versions simple" {
    const ics = try Self.parse(std.testing.allocator, &.{">=2.7"});
    defer ics.deinit();

    var actual_versions = std.ArrayList(PythonVersion).init(std.testing.allocator);
    defer actual_versions.deinit();

    var iter = ics.compatible_versions_iter(.{ .max = .{ .minor = 6 } });
    while (iter.next()) |version| try actual_versions.append(version);

    try std.testing.expectEqualDeep(
        &.{
            PythonVersion{ .major = 2, .minor = 7 },
            PythonVersion{ .major = 3, .minor = 5 },
            PythonVersion{ .major = 3, .minor = 6 },
        },
        actual_versions.items,
    );
}

test "Compatible versions ORed" {
    const ics = try Self.parse(std.testing.allocator, &.{ "PyPy~=3.11", "==3.8.*" });
    defer ics.deinit();

    var actual_versions = std.ArrayList(PythonVersion).init(std.testing.allocator);
    defer actual_versions.deinit();

    var iter = ics.compatible_versions_iter(.{ .max = .{ .minor = 14 } });
    while (iter.next()) |version| try actual_versions.append(version);

    try std.testing.expectEqualDeep(
        &.{
            PythonVersion{ .major = 3, .minor = 8 },
            PythonVersion{ .major = 3, .minor = 11, .impl = .PyPy },
            PythonVersion{ .major = 3, .minor = 12, .impl = .PyPy },
            PythonVersion{ .major = 3, .minor = 13, .impl = .PyPy },
            PythonVersion{ .major = 3, .minor = 14, .impl = .PyPy },
        },
        actual_versions.items,
    );
}
