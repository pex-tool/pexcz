const std = @import("std");

const Interpreter = @import("Interpreter.zig");
const fs = @import("fs.zig");
const os = @import("os.zig");

const Self = @This();

const log = std.log.scoped(.pex_python);

value: ?os.Value = null,

pub fn fromEnv(allocator: std.mem.Allocator) !Self {
    const value = try os.getEnv(allocator, "PEX_PYTHON");
    if (value) |python| {
        errdefer python.deinit();
        if (!std.fs.path.isAbsolute(python.value) and std.mem.indexOf(u8, python.value, std.fs.path.sep_str) != null) {
            log.err("Invalid PEX_PYTHON: {s}. Must be either an absolute path to a Python " ++
                "binary or a Python binary name (like \"python3.12\")", .{python.value});
            return error.InvalidPexPython;
        }
    }
    return .{ .value = value };
}

pub fn matches(self: Self, interpreter: Interpreter) bool {
    if (self.value) |python| {
        if (std.fs.path.isAbsolute(python.value)) {
            return fs.contains(interpreter.prefix, python.value);
        } else {
            // TODO(John Sirois): Handle PEX_PYTHON=python3.8 vs a basename of python or python3
            const basename = std.fs.path.basename(interpreter.path);
            return std.mem.eql(u8, python.value, basename);
        }
    } else {
        return true;
    }
}

pub fn deinit(self: Self) void {
    if (self.value) |value| {
        value.deinit();
    }
}
