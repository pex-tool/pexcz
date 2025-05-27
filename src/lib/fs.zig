const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const getenv = @import("os.zig").getenv;

const TempDirRoot = struct {
    path: []const u8,
    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    fn deinit(self: *Self) void {
        if (self.allocator) |allocator| {
            allocator.free(self.path);
            self.allocator = null;
        }
    }

    fn join(self: Self, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        return try std.fs.path.join(allocator, &.{ self.path, path });
    }
};

fn tempDirRoot(allocator: std.mem.Allocator) !TempDirRoot {
    // Via Python: https://docs.python.org/3/library/tempfile.html#tempfile.gettempdir
    // Return the name of the directory used for temporary files. This defines the default value
    // for the dir argument to all functions in this module.
    //
    // Python searches a standard list of directories to find one which the calling user can create
    // files in. The list is:
    //     The directory named by the TMPDIR environment variable.
    //     The directory named by the TEMP environment variable.
    //     The directory named by the TMP environment variable.
    //     A platform-specific location:
    //         On Windows, the directories C:\TEMP, C:\TMP, \TEMP, and \TMP, in that order.
    //         On all other platforms, the directories /tmp, /var/tmp, and /usr/tmp, in that order.
    //     As a last resort, the current working directory.
    //
    // The result of this search is cached.
    //
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |key| {
        if (try getenv(allocator, key)) |tmp| {
            return .{ .path = tmp.value, .allocator = tmp.allocator };
        }
    }
    const paths = res: {
        if (native_os == .windows) {
            break :res [_][]const u8{ "C:\\TEMP", "C:\\TMP", "\\TEMP", "\\TMP" };
        } else {
            break :res [_][]const u8{ "/tmp", "/var/tmp", "/usr/tmp" };
        }
    };
    for (&paths) |path| {
        if (std.fs.accessAbsolute(path, .{ .mode = .read_write })) |_| {
            return .{ .path = path };
        } else |_| {}
    }
    return .{ .path = "." };
}

pub const TempDirs = struct {
    const TempDir = struct {
        path: []const u8,
        cleanup: bool,

        fn deinit(self: @This(), allocator: std.mem.Allocator) !void {
            defer allocator.free(self.path);
            if (self.cleanup) {
                return std.fs.cwd().deleteTree(self.path);
            }
        }
    };

    allocator: std.mem.Allocator,
    temp_dirs: std.ArrayList(TempDir),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .temp_dirs = .init(allocator) };
    }

    pub fn mkdtemp(self: *Self, cleanup: bool) ![]const u8 {
        var td = try tempDirRoot(self.allocator);
        defer td.deinit();

        const encoder = std.fs.base64_encoder;
        var rand_buf: [8]u8 = undefined;
        var tmp_name_buf: [11]u8 = undefined;
        std.debug.assert(tmp_name_buf.len == encoder.calcSize(rand_buf.len));
        for (0..5) |attempt| {
            (res: {
                var engine = std.Random.DefaultPrng.init(@abs(std.time.microTimestamp()));
                break :res engine.random();
            }).bytes(&rand_buf);
            const tmp_name = encoder.encode(&tmp_name_buf, &rand_buf);
            const dir_path = try td.join(self.allocator, tmp_name);
            errdefer self.allocator.free(dir_path);
            std.fs.cwd().makeDir(dir_path) catch |err| {
                std.debug.print(
                    "[attempt {d} of 5] Failed to create temp dir {s}: {}\n",
                    .{ attempt + 1, dir_path, err },
                );
                continue;
            };
            try self.temp_dirs.append(TempDir{ .path = dir_path, .cleanup = cleanup });
            return dir_path;
        }
        return error.NonUnique;
    }

    pub fn deinit(self: Self) void {
        for (self.temp_dirs.items) |temp_dir| {
            temp_dir.deinit(self.allocator) catch |err| {
                std.debug.print("Failed to cleanup temp dir {}: {}\n", .{ temp_dir, err });
                continue;
            };
        }
        self.temp_dirs.deinit();
    }
};
