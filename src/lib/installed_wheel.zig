const std = @import("std");
const Virtualenv = @import("Virtualenv.zig");

pub fn installInVenv(
    alloc: std.mem.Allocator,
    wp: []const u8,
    virtualenv: *const Virtualenv,
    site_packages_dir_path: []const u8,
    entry_name: []const u8,
) !void {
    var wd = try std.fs.cwd().openDir(wp, .{});
    defer wd.close();

    var site_packages = try std.fs.cwd().openDir(site_packages_dir_path, .{});
    defer site_packages.close();

    const wheel_dir_relpath = try std.fs.path.join(alloc, &.{ ".deps", entry_name });
    defer alloc.free(wheel_dir_relpath);

    var wheel_dir = try site_packages.openDir(wheel_dir_relpath, .{ .iterate = true });
    defer wheel_dir.close();

    var wheel_dir_iter = wheel_dir.iterate();
    while (try wheel_dir_iter.next()) |wheel_entry| {
        if (std.mem.eql(u8, ".layout.json", wheel_entry.name)) {
            continue;
        } else if (std.mem.eql(
            u8,
            ".prefix",
            wheel_entry.name,
        ) and wheel_entry.kind == .directory) {
            var prefix_dir = try wheel_dir.openDir(".prefix", .{ .iterate = true });
            defer prefix_dir.close();

            var prefix_walker = try prefix_dir.walk(alloc);
            defer prefix_walker.deinit();

            const prefix_dir_path = try std.fs.path.join(
                alloc,
                &.{
                    wp,
                    virtualenv.site_packages_relpath,
                    ".deps",
                    entry_name,
                    ".prefix",
                },
            );
            defer alloc.free(prefix_dir_path);

            while (try prefix_walker.next()) |prefix_entry| {
                if (prefix_entry.kind == .directory) {
                    continue;
                }
                const prefix_entry_path = try std.fs.path.join(
                    alloc,
                    &.{ prefix_dir_path, prefix_entry.path },
                );
                defer alloc.free(prefix_entry_path);

                if (std.fs.path.dirname(prefix_entry.path)) |parent_dir_relpath| {
                    try wd.makePath(parent_dir_relpath);
                }
                try wd.rename(prefix_entry_path, prefix_entry.path);
            }
        } else {
            if (wheel_entry.kind == .directory) {
                var wheel_entry_dir = try wheel_dir.openDir(
                    wheel_entry.name,
                    .{ .iterate = true },
                );
                defer wheel_entry_dir.close();

                var wheel_entry_dir_walker = try wheel_entry_dir.walk(alloc);
                defer wheel_entry_dir_walker.deinit();

                const wheel_entry_dir_path = try std.fs.path.join(
                    alloc,
                    &.{
                        wp,
                        virtualenv.site_packages_relpath,
                        ".deps",
                        entry_name,
                        wheel_entry.name,
                    },
                );
                defer alloc.free(wheel_entry_dir_path);

                var target_dir = try site_packages.makeOpenPath(wheel_entry.name, .{});
                defer target_dir.close();
                while (try wheel_entry_dir_walker.next()) |wheel_entry_dir_entry| {
                    if (wheel_entry_dir_entry.kind == .directory) {
                        continue;
                    }
                    const wheel_entry_path = try std.fs.path.join(
                        alloc,
                        &.{ wheel_entry_dir_path, wheel_entry_dir_entry.path },
                    );
                    defer alloc.free(wheel_entry_path);

                    if (std.fs.path.dirname(wheel_entry_dir_entry.path)) |parent_dir| {
                        try target_dir.makePath(parent_dir);
                    }
                    try target_dir.rename(wheel_entry_path, wheel_entry_dir_entry.path);
                }
            } else {
                const wheel_entry_relpath = try std.fs.path.join(
                    alloc,
                    &.{ ".deps", entry_name, wheel_entry.name },
                );
                defer alloc.free(wheel_entry_relpath);
                try site_packages.rename(wheel_entry_relpath, wheel_entry.name);
            }
        }
    }
}
