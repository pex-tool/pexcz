const std = @import("std");
const fs = std.fs;
const File = fs.File;

const mkdtemp = @import("fs.zig").mkdtemp;
const parse_pex_info = @import("pex_info.zig").parse;
const ZipFile = @import("zip.zig").Zip(std.fs.File.SeekableStream);
const venv = @import("Virtualenv.zig");

pub fn bootPexZ(python_exe_path: [*:0]const u8, pex_path: [*:0]const u8) !void {
    var timer = try std.time.Timer.start();
    defer std.debug.print("boot_pex({s}, {s}) took {d:.3}µs\n", .{ python_exe_path, pex_path, timer.read() / 1_000 });

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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    const extract_dir_path = try mkdtemp(allocator);
    defer allocator.free(extract_dir_path);
    defer {
        fs.cwd().deleteTree(extract_dir_path) catch |err| {
            std.debug.print("Failed to clean up extra dir {s}: {}\n", .{ extract_dir_path, err });
        };
    }
    var extract_dir = try fs.cwd().openDir(extract_dir_path, .{});
    defer extract_dir.close();

    try pex_info_entry.extract_from_stream(zip_stream, extract_dir);

    const pex_info_path = try fs.path.join(allocator, &.{ extract_dir_path, "PEX-INFO" });
    defer allocator.free(pex_info_path);

    const pex_info_file = try fs.cwd().openFile(pex_info_path, .{});
    const pex_info_file_md = try pex_info_file.metadata();

    const data = try pex_info_file.readToEndAlloc(allocator, pex_info_file_md.size());
    defer allocator.free(data);

    const pex_info = try parse_pex_info(allocator, data);
    std.debug.print("Read PEX-INFO: {}\n", .{pex_info});

    std.debug.print("TODO: zig-boot!!: {s}\n", .{pex_path});

    _ = std.fs.cwd().makeDir("/tmp/extract") catch {
        std.debug.print("(/tmp/extract already exists)\n", .{});
    };
    const dest = try fs.cwd().openDir("/tmp/extract", .{});
    std.debug.print("Opened: /tmp/extract\n", .{});

    if (zip_file.entry("__main__.py")) |main| {
        try main.extract_from_stream(zip_stream, dest);
        std.debug.print("Extracted {s}/__main__.py to {?}\n", .{ pex_path, dest });
    } else {
        std.debug.print("No __main__.py entry found in {s}!\n", .{pex_path});
    }
}
