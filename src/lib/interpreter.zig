const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const cache = @import("cache.zig");
const TempDirs = @import("fs.zig").TempDirs;

const interpreter_py = @embedFile("interpreter.py");

pub const VersionInfo = struct {
    major: u8,
    minor: u8,
    micro: u8,
    releaselevel: []const u8,
    serial: u8,
};

pub const MarkerEnv = struct {
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
};

pub const Interpreter = struct {
    path: []const u8,
    prefix: []const u8,
    base_prefix: ?[]const u8,
    version: VersionInfo,
    marker_env: MarkerEnv,
    macos_framework_build: bool,
    // TODO: XXX: add supported tags.

    const Self = @This();

    pub fn identify(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Self) {
        var temp_dirs = TempDirs.init(allocator);
        defer temp_dirs.deinit();

        const pexcz_root = try cache.root(allocator, &temp_dirs, .{});
        defer pexcz_root.deinit(.{});

        // TODO(John Sirois): Re-consider key hashing scheme - compare to Pex.
        const Hasher = std.crypto.hash.sha2.Sha256;
        var hasher = Hasher.init(.{});
        hasher.update(path);
        const encoder = std.fs.base64_encoder;
        // N.B.: This is the correct value for a 32 byte hash (sha256).
        var key_buf: [43]u8 = undefined;
        const key = encoder.encode(&key_buf, &hasher.finalResult());
        const expected_size = encoder.calcSize(Hasher.digest_length);
        std.debug.assert(expected_size == key.len);

        var interpeter_cache = try pexcz_root.join(&.{ "interpreters", "0", key });
        defer interpeter_cache.deinit(.{});

        const Work = struct {
            allocator: std.mem.Allocator,
            python: []const u8,

            fn work(work_path: []const u8, work_dir: std.fs.Dir, context: @This()) !void {
                const result = try std.process.Child.run(.{
                    .allocator = context.allocator,
                    .argv = &.{ context.python, "-sE", "-c", interpreter_py, "info.json" },
                    .cwd = work_path,
                    .cwd_dir = work_dir,
                });
                context.allocator.free(result.stdout);
                context.allocator.free(result.stderr);
                errdefer std.debug.print(
                    \\Failed to identify interpreter at {s}.
                    \\
                    \\STDOUT:
                    \\{s}
                    \\
                    \\STDERR:
                    \\{s}
                    \\
                ,
                    .{ context.python, result.stdout, result.stderr },
                );
                switch (result.term) {
                    .Exited => |code| if (code != 0) return error.InterpreterIdentificationError,
                    else => return error.InterpreterIdentificationError,
                }
            }
        };
        const work: Work = .{ .allocator = allocator, .python = path };
        var interpeter_cache_dir = try interpeter_cache.createAtomic(Work, Work.work, work, .{});
        defer interpeter_cache_dir.close();

        var buf: [100 * 1024]u8 = undefined;
        const data = try interpeter_cache_dir.readFile("info.json", &buf);
        std.debug.assert(data.len < buf.len);

        return try std.json.parseFromSlice(
            Interpreter,
            allocator,
            data,
            .{ .allocate = .alloc_always },
        );
    }
};

pub const InterpreterIter = struct {
    pub fn next() ?Interpreter {
        return null;
    }
};
