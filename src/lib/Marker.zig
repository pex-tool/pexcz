const std = @import("std");

pub const Env = struct {
    os_name: []const u8,
    sys_platform: []const u8,
    platform_machine: []const u8,
    platform_python_implementation: []const u8,
    platform_release: []const u8,
    platform_system: []const u8,
    platform_version: []const u8,
    python_version: []const u8,
    python_full_version: []const u8,
    implementation_name: []const u8,
    implementation_version: []const u8,

    pub fn is_pypy(self: @This()) bool {
        return std.mem.eql(u8, "PyPy", self.platform_python_implementation);
    }
};
