const std = @import("std");
const File = fs.File;
const builtin = @import("builtin");

const Allocator = @import("heap.zig").Allocator;
const parse_pex_info = @import("pex_info.zig").parse;
const venv = @import("Virtualenv.zig");
const cache = @import("cache.zig");
const fs = @import("fs.zig");

const ZipFile = @import("zip.zig").Zip(std.fs.File.SeekableStream);
pub fn bootPexZ(python_exe_path: [*:0]const u8, pex_path: [*:0]const u8) !void {
    var timer = try std.time.Timer.start();
    defer std.debug.print(
        "boot_pex({s}, {s}) took {d:.3}µs\n",
        .{ python_exe_path, pex_path, timer.read() / 1_000 },
    );

    // [ ] 1. Check if current interpreter + PEX has cached venv and re-exec to it if so.
    //     + Load PEX-INFO to get: `pex_hash`.
    // [ ] 2. Find viable interpreter for PEX to create venv with.
    //     + Load PEX-INFO to get: `interpreter_constraints
    //     + Load PEX-INFO to get dep resolve info:
    //       * `distributions`
    //       * `requirements`
    //       * `overridden`
    //       * `excluded`
    // [ ] 3. Create venv.
    //     + Load PEX-INFO to get:
    //       * `venv_system_site_packages`
    //       * `venv_hermetic_scripts`
    //       * `venv_bin_path`
    // [ ] 4. Populate venv.
    //     + Load PEX-INFO to get dep install info:
    //       * `deps_are_wheel_files`
    //     + Load PEX-INFO to get __main__ info:
    //       * `entry_point`
    //       * `inherit_path
    //       * `inject_python_args``
    //       * `inject_args`
    //       * `inject_env`
    // [ ] 5. Re-exec to venv.

    var alloc = Allocator(.{ .safety = true, .verbose_log = true }).init();
    defer alloc.deinit();
    const allocator = alloc.allocator();

    var temp_dirs = fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();

    var venv_lines = std.mem.splitSequence(u8, venv.VIRTUALENV_PY, "\n");
    std.debug.print("Embedded virtualenv.py:\n{s}\n...\n", .{venv_lines.first()});

    var pex_file = try std.fs.cwd().openFileZ(pex_path, .{});
    defer pex_file.close();
    const zip_stream = pex_file.seekableStream();
    var zip_file = try ZipFile.init(allocator, zip_stream);
    defer zip_file.deinit(allocator);

    const pex_info_entry = zip_file.entry("PEX-INFO") orelse {
        std.debug.print("Failed to find PEX-INFO in {s}\n", .{pex_path});
        return error.PexInfoNotFound;
    };

    const data = try pex_info_entry.extract_to_slice(allocator, zip_stream);
    defer allocator.free(data);

    const pex_info = try parse_pex_info(allocator, data);
    defer pex_info.deinit();
    std.debug.print("Read PEX-INFO: {}\n", .{pex_info});

    std.debug.print("TODO: zig-boot!!: {s}\n", .{pex_path});

    const encoder = std.fs.base64_encoder;
    const pex_hash_bytes = @as(
        [20]u8,
        @bitCast(try std.fmt.parseUnsigned(u160, pex_info.value.pex_hash, 16)),
    );
    var encoded_pex_hash_buf: [27]u8 = undefined;
    std.debug.assert(encoded_pex_hash_buf.len == encoder.calcSize(pex_hash_bytes.len));
    const pex_hash = encoder.encode(&encoded_pex_hash_buf, &pex_hash_bytes);

    const pexcz_root = try cache.root(allocator, &temp_dirs, .{});
    defer pexcz_root.deinit(.{});

    var venv_cache_dir = try pexcz_root.join(&.{ "venvs", "0", pex_hash });
    defer venv_cache_dir.deinit(.{});

    const Fn = struct {
        fn touch(work_dir: std.fs.Dir) !void {
            const proof = try work_dir.createFile("proof", .{});
            defer proof.close();
        }
    };
    _ = try venv_cache_dir.createAtomic(Fn.touch);
    std.debug.print("Write locked venv cache dir: {s}\n", .{venv_cache_dir.path});
}
