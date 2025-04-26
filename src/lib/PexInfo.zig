const std = @import("std");

pub const BinPath = enum { false, append, prepend };

pub const InheritPath = enum { false, prefer, fallback };

pex_hash: []const u8,
distributions: std.json.ArrayHashMap([]const u8),
requirements: []const []const u8,
overridden: []const []const u8,
excluded: []const []const u8,
interpreter_constraints: []const []const u8,
venv_system_site_packages: bool,
venv_hermetic_scripts: bool,
venv_bin_path: ?BinPath,
deps_are_wheel_files: bool,
inherit_path: ?InheritPath,
inject_python_args: []const []const u8,
inject_args: []const []const u8,
inject_env: std.json.ArrayHashMap([]const u8),
entry_point: ?[]const u8 = null,
script: ?[]const u8 = null,
strip_pex_env: ?bool = null,

const Self = @This();

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Self) {
    return std.json.parseFromSlice(
        Self,
        allocator,
        data,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}
