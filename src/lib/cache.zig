const std = @import("std");
const known_folders = @import("known-folders");

const fs = @import("fs.zig");

pub const CacheDir = struct {
    const Lock = struct {
        file: std.fs.File,
        mode: std.fs.File.Lock,

        fn lock(self: *@This(), mode: std.fs.File.Lock) !bool {
            if (mode == self.mode) {
                return false;
            }
            switch (mode) {
                .shared => try self.file.downgradeLock(),
                .exclusive => try self.file.lock(.exclusive),
                .none => self.file.unlock(),
            }
            self.mode = mode;
            return true;
        }

        fn unlock(self: @This()) void {
            if (self.mode != .none) {
                self.file.unlock();
            }
            self.file.close();
        }
    };

    allocator: std.mem.Allocator,
    path: []const u8,
    lock: ?Lock = null,

    const Self = @This();

    pub fn readLock(self: *Self) !bool {
        return self.ensureLock(.shared);
    }

    pub fn writeLock(self: *Self) !bool {
        return self.ensureLock(.exclusive);
    }

    pub fn unlock(self: *Self) bool {
        if (self.lock) |*lock| {
            lock.unlock();
            lock = null;
            return true;
        }
        return false;
    }

    fn ensureLock(self: *Self, mode: std.fs.File.Lock) !bool {
        if (self.lock) |*lock| {
            return lock.lock(mode);
        }

        const path = try std.fs.path.join(self.allocator, &.{ self.path, ".lock" });
        defer self.allocator.free(path);

        try std.fs.cwd().makePath(self.path);

        const file = try std.fs.cwd().createFile(path, .{ .lock = mode });
        self.lock = .{ .file = file, .mode = mode };
        return true;
    }

    pub fn join(self: Self, subpaths: []const []const u8) !Self {
        const cache_dir_path = res: {
            if (subpaths.len == 1) {
                break :res try std.fs.path.join(self.allocator, &.{ self.path, subpaths[0] });
            } else if (subpaths.len == 2) {
                break :res try std.fs.path.join(self.allocator, &.{ self.path, subpaths[0], subpaths[1] });
            } else if (subpaths.len == 3) {
                break :res try std.fs.path.join(self.allocator, &.{ self.path, subpaths[0], subpaths[1], subpaths[2] });
            }

            var total_len = self.path.len;
            for (subpaths) |subpath| {
                total_len += subpath.len;
            }
            var paths = try std.ArrayList([]const u8).initCapacity(self.allocator, total_len);
            defer paths.deinit();
            try paths.append(self.path);
            try paths.appendSlice(subpaths);
            break :res try std.fs.path.join(self.allocator, paths.items);
        };
        return .{ .allocator = self.allocator, .path = cache_dir_path };
    }

    pub const DeinitOptions = struct {
        release_lock: bool = true,
    };

    pub fn deinit(self: Self, options: DeinitOptions) void {
        self.allocator.free(self.path);
        if (!options.release_lock) {
            return;
        }
        if (self.lock) |lock| {
            lock.unlock();
        }
    }
};

pub const AccessOptions = struct {
    exclusive: bool = false,
};

pub fn root(
    allocator: std.mem.Allocator,
    temp_dirs: *fs.TempDirs,
    options: AccessOptions,
) !CacheDir {
    const cache_path = res: {
        if (try known_folders.getPath(allocator, .cache)) |cache| {
            defer allocator.free(cache);
            const cache_path = try std.fs.path.join(allocator, &.{ cache, "pexcz" });
            break :res cache_path;
        } else {
            const tmp_cache = try temp_dirs.mkdtemp(true);
            std.debug.print(
                \\The user cache directory could not be determined, using a temporary cache dir at:
                \\  {s}
                \\
            ,
                .{tmp_cache},
            );
            const cache_path = try std.fs.path.join(allocator, &.{ tmp_cache, "pexcz-cache" });
            break :res cache_path;
        }
    };
    var cache: CacheDir = .{ .allocator = allocator, .path = cache_path };
    errdefer cache.deinit(.{});
    _ = try if (options.exclusive) cache.writeLock() else cache.readLock();
    return cache;
}

test "cache root" {
    const allocator = std.testing.allocator;

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    const pexcz_root = try root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});
}

test "cache subdir" {
    const allocator = std.testing.allocator;

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    const pexcz_root = try root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});

    const expected_venvs = try std.fs.path.join(allocator, &.{ pexcz_root.path, "venvs", "0" });
    defer allocator.free(expected_venvs);

    const venvs = try pexcz_root.join(&.{ "venvs", "0" });
    defer venvs.deinit(.{});

    try std.testing.expectEqualSlices(u8, expected_venvs, venvs.path);
}

test "lock upgrade downgrade" {
    const allocator = std.testing.allocator;

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    var pexcz_root = try root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});

    try std.testing.expectEqual(std.fs.File.Lock.shared, pexcz_root.lock.?.mode);

    try std.testing.expect(try pexcz_root.writeLock());
    try std.testing.expectEqual(std.fs.File.Lock.exclusive, pexcz_root.lock.?.mode);

    try std.testing.expect(!try pexcz_root.writeLock());
    try std.testing.expectEqual(std.fs.File.Lock.exclusive, pexcz_root.lock.?.mode);

    try std.testing.expect(try pexcz_root.readLock());
    try std.testing.expectEqual(std.fs.File.Lock.shared, pexcz_root.lock.?.mode);

    try std.testing.expect(!try pexcz_root.readLock());
    try std.testing.expectEqual(std.fs.File.Lock.shared, pexcz_root.lock.?.mode);
}
