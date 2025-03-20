const std = @import("std");
const known_folders = @import("known-folders");

const fs = @import("fs.zig");

pub fn root(allocator: std.mem.Allocator, temp_dirs: *fs.TempDirs) ![]const u8 {
    return subdir(allocator, temp_dirs, &.{});
}

pub fn subdir(allocator: std.mem.Allocator, temp_dirs: *fs.TempDirs, subpaths: []const []const u8) ![]const u8 {
    const cache = res: {
        if (try known_folders.getPath(allocator, .cache)) |cache| {
            defer allocator.free(cache);
            break :res try std.fs.path.join(allocator, &.{ cache, "pexcz" });
        } else {
            const tmp_cache = try temp_dirs.mkdtemp(true);
            std.debug.print(
                \\The user cache directory could not be determined, using a temporary cache dir at:
                \\  {s}
                \\
            ,
                .{tmp_cache},
            );
            break :res try std.fs.path.join(allocator, &.{ tmp_cache, "pexcz-cache" });
        }
    };

    if (subpaths.len == 0) {
        return cache;
    }

    defer allocator.free(cache);
    if (subpaths.len == 1) {
        return std.fs.path.join(allocator, &.{ cache, subpaths[0] });
    } else if (subpaths.len == 2) {
        return std.fs.path.join(allocator, &.{ cache, subpaths[0], subpaths[1] });
    } else if (subpaths.len == 3) {
        return std.fs.path.join(allocator, &.{ cache, subpaths[0], subpaths[1], subpaths[2] });
    }

    var total_len = cache.len;
    for (subpaths) |subpath| {
        total_len += subpath.len;
    }
    var paths = try std.ArrayList([]const u8).initCapacity(allocator, total_len);
    defer paths.deinit();
    try paths.append(cache);
    try paths.appendSlice(subpaths);
    return std.fs.path.join(allocator, paths.items);
}

test "cache root" {
    const allocator = std.testing.allocator;

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    const pexcz_root = try root(allocator, &temp_dirs);
    defer allocator.free(pexcz_root);
}

test "cache subdir" {
    const allocator = std.testing.allocator;

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    const pexcz_root = try root(allocator, &temp_dirs);
    defer allocator.free(pexcz_root);

    const expected_venvs = try std.fs.path.join(allocator, &.{ pexcz_root, "venvs", "0" });
    defer allocator.free(expected_venvs);

    const venvs = try subdir(allocator, &temp_dirs, &.{ "venvs", "0" });
    defer allocator.free(venvs);

    try std.testing.expectEqualSlices(u8, expected_venvs, venvs);
}
