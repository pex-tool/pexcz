const std = @import("std");
const builtin = @import("builtin");

fn temp_dir(allocator: std.mem.Allocator) ![]const u8 {
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
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |key| {
        if (env.get(key)) |tmp| {
            return tmp;
        }
    }
    const paths = res: {
        if (builtin.target.os.tag == .windows) {
            break :res [_][]const u8{ "C:\\TEMP", "C:\\TMP", "\\TEMP", "\\TMP" };
        } else {
            break :res [_][]const u8{ "/tmp", "/var/tmp", "/usr/tmp" };
        }
    };
    for (&paths) |path| {
        if (std.fs.accessAbsolute(path, .{ .mode = .read_write })) |_| {
            return path;
        } else |_| {}
    }
    return ".";
}

pub fn mkdtemp(allocator: std.mem.Allocator) ![]const u8 {
    const temp_dir_path = try temp_dir(allocator);

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
        const dir_path = try std.mem.concat(
            allocator,
            u8,
            &.{ temp_dir_path, std.fs.path.sep_str, tmp_name },
        );
        std.fs.cwd().makeDir(dir_path) catch |err| {
            std.debug.print(
                "[attempt {d} of 5] Failed to create temp dir {s}: {}\n",
                .{ attempt + 1, dir_path, err },
            );
            continue;
        };
        return dir_path;
    }
    return error.NonUnique;
}
