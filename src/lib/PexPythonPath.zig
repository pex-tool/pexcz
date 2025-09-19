const std = @import("std");

const Interpreter = @import("Interpreter.zig");
const fs = @import("fs.zig");
const os = @import("os.zig");

const Self = @This();

entries: ?[]const []const u8 = null,

pub fn fromEnv(allocator: std.mem.Allocator) !Self {
    if (try os.getEnv(allocator, "PEX_PYTHON_PATH")) |pex_python_path| {
        defer pex_python_path.deinit();

        var path = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (path.items) |item| {
                allocator.free(item);
            }
            path.deinit();
        }

        var path_iter = std.mem.splitScalar(
            u8,
            pex_python_path.value,
            std.fs.path.delimiter,
        );
        while (path_iter.next()) |entry| {
            try path.append(try allocator.dupe(u8, entry));
        }
        return .{ .entries = try path.toOwnedSlice() };
    } else {
        return .{};
    }
}

pub fn contains(self: Self, interpreter: Interpreter) !bool {
    if (self.entries) |entries| {
        for (entries) |entry| {
            if (try fs.contains(entry, interpreter.path)) return true;
        }
    }
    return false;
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    if (self.entries) |entries| {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
}
