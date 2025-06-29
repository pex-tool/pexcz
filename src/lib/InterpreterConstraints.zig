const builtin = @import("builtin");
const std = @import("std");
const Interpreter = @import("interpreter.zig").Interpreter;
const Specifier = @import("Specifier.zig");

fn trim_ws(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r");
}

const PythonImplementation = enum { CPython, PyPy };

const InterpreterConstraint = struct {
    impl: ?PythonImplementation,
    specifier: Specifier,

    fn parse(allocator: std.mem.Allocator, constraint: []const u8) !InterpreterConstraint {
        const trimmed = trim_ws(constraint);
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
        return .{ .impl = impl, .specifier = try Specifier.parse(allocator, constraint[index..]) };
    }

    fn deinit(self: InterpreterConstraint) void {
        self.specifier.deinit();
    }

    pub fn matches(self: InterpreterConstraint, allocator: std.mem.Allocator, interp: Interpreter) !bool {
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
        return self.specifier.matches(allocator, interp.marker_env.python_full_version);
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

pub fn matches(self: Self, allocator: std.mem.Allocator, interp: Interpreter) !bool {
    if (self.constraints.len == 0) return true;
    for (self.constraints) |constraint| {
        if (try constraint.matches(allocator, interp)) return true;
    }
    return false;
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

    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython38.value));
    try std.testing.expect(try ics.matches(std.testing.allocator, pythons.cpython39.value));
    try std.testing.expect(try ics.matches(std.testing.allocator, pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(try ics.matches(std.testing.allocator, pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(try ics.matches(std.testing.allocator, pypy311.value));
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

    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython38.value));
    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython39.value));
    try std.testing.expect(try ics.matches(std.testing.allocator, pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy311.value));
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

    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython38.value));
    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython39.value));
    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(try ics.matches(std.testing.allocator, pypy311.value));
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

    try std.testing.expect(try ics.matches(std.testing.allocator, pythons.cpython38.value));
    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython39.value));
    try std.testing.expect(!try ics.matches(std.testing.allocator, pythons.cpython312.value));
    if (pythons.pypy38) |pypy38| {
        try std.testing.expect(try ics.matches(std.testing.allocator, pypy38.value));
    }
    if (pythons.pypy310) |pypy310| {
        try std.testing.expect(!try ics.matches(std.testing.allocator, pypy310.value));
    }
    if (pythons.pypy311) |pypy311| {
        try std.testing.expect(try ics.matches(std.testing.allocator, pypy311.value));
    }
}
