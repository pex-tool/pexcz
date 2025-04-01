const native_os = @import("builtin").target.os.tag;
const std = @import("std");

pub const Value = struct {
    allocator: ?std.mem.Allocator = null,
    value: []const u8,

    const Self = @This();

    pub fn deinit(self: Self) void {
        if (self.allocator) |allocator| {
            allocator.free(self.value);
        }
    }
};

pub fn getenv(allocator: std.mem.Allocator, name: []const u8) !?Value {
    if (native_os == .windows) {
        const w_key = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(w_key);

        var lpBuffer: [32_767:0]u16 = undefined;
        const len = std.os.windows.GetEnvironmentVariableW(
            w_key,
            &lpBuffer,
            lpBuffer.len,
        ) catch |err| {
            switch (err) {
                error.EnvironmentVariableNotFound => return null,
                else => return err,
            }
        };
        const value_w = lpBuffer[0..len];
        return .{
            .allocator = allocator,
            .value = try std.unicode.utf16LeToUtf8Alloc(allocator, value_w),
        };
    } else if (std.posix.getenv(name)) |value| {
        return .{ .value = value };
    } else {
        return null;
    }
}
