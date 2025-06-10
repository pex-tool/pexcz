const builtin = @import("builtin");
const std = @import("std");
const native_os = builtin.target.os.tag;

const pexcz = @import("pexcz");
const Allocator = pexcz.Allocator;
const Zip = pexcz.Zip;
const c = Zip.c;
const config = @import("config");

const EmbeddedLib = struct {
    []const u8,
    []const u8,
};

fn genLibMap() ![config.libs.len]EmbeddedLib {
    var embedded_libs: [config.libs.len]EmbeddedLib = undefined;
    comptime var i = 0;
    inline for (config.libs) |target_dir| {
        const lib_path = @field(config, target_dir);
        const lib_data = @embedFile(lib_path);
        embedded_libs[i][0] = lib_path[config.libs_root.len + 1 ..];
        embedded_libs[i][1] = lib_data;
        i += 1;
    }
    return embedded_libs;
}

const libs = std.StaticStringMap([]const u8).initComptime(genLibMap() catch unreachable);

const __main__: []const u8 = @embedFile("python/pexcz/__init__.py");

const log = std.log.scoped(.pexcz);

fn help(prog: []const u8) void {
    std.debug.print(
        \\Usage: {s} --help | inject <PEX>
        \\
        \\ inject:  Inject a pexcz bootstrap in the given PEX file.
        \\
        \\General Options:
        \\ -h, --help:  Print this help and exit.
        \\
    ,
        .{prog},
    );
}

fn usage(prog: []u8, message: []const u8) u8 {
    std.debug.print(
        \\Usage: {s} --help | inject <PEX>
        \\
        \\{s}
    ,
        .{ prog, message },
    );
    return 1;
}

const CompressionOptions = struct {
    method: Zip.Compression = .deflate,
    level: i8 = 0,
};

fn setZipPrefix(allocator: std.mem.Allocator, pex: *Zip, czex: *Zip) !?[]const u8 {
    const prefix = c.zip_get_archive_prefix(pex.handle);
    if (prefix == 0) {
        return null;
    }
    if (prefix > std.math.maxInt(usize)) {
        log.err(
            "The zip prefix for {s} is {d} bytes which is too large for this system " ++
                "to process: {s}",
            .{ czex.path, prefix, c.zip_strerror(czex.handle) },
        );
        return error.ZipPrefixTooBig;
    }
    const buffer = try allocator.alloc(u8, @intCast(prefix));
    errdefer allocator.free(buffer);

    var source_pex_file = try std.fs.cwd().openFileZ(pex.path, .{});
    defer source_pex_file.close();

    var source_pex_fp = std.io.bufferedReader(source_pex_file.reader());
    const read_amount = try source_pex_fp.reader().readAll(buffer);
    std.debug.assert(read_amount == buffer.len);

    if (c.zip_set_archive_prefix(czex.handle, buffer.ptr, buffer.len) != 0) {
        log.err(
            "Failed to set Pex shebang prefix on {s}: {s}",
            .{ czex.path, c.zip_strerror(czex.handle) },
        );
        return error.ZipAddPrefixError;
    }
    return buffer;
}

fn setEntryMtime(pex: *Zip, entry_index: c.zip_uint64_t, entry_name: []const u8) !void {
    const res = c.zip_file_set_dostime(
        pex.handle,
        entry_index,
        // This is January 1st 1980 00:00:00.
        // See: https://libzip.org/documentation/zip_file_set_dostime.html#DESCRIPTION
        // hr   min    sec
        0b00000_000000_00000, // time
        // 1980+  mon  day
        0b0000000_0001_00001, // date
        0,
    );
    if (res < 0) {
        log.err(
            "Failed to set mtime on {s} file entry in {s}: {s}",
            .{ entry_name, pex.path, c.zip_strerror(pex.handle) },
        );
        return error.ZipEntryAddMainError;
    }
}

fn transferEntries(
    source_pex: *Zip,
    dest_pex: *Zip,
    options: CompressionOptions,
) !void {
    next_entry: for (0..source_pex.num_entries) |index| {
        const entry_name = std.mem.span(c.zip_get_name(
            source_pex.handle,
            @intCast(index),
            0,
        ) orelse {
            log.err("Failed to get name of entry {d} from {s}.", .{ index, source_pex.path });
            return error.ZipEntryMetadataError;
        });

        if (std.mem.eql(u8, entry_name, "__main__.py")) {
            continue;
        }
        for ([_][]const u8{ ".bootstrap/", "__pex__/" }) |prefix| {
            if (std.mem.startsWith(u8, entry_name, prefix)) {
                continue :next_entry;
            }
        }

        if (std.mem.endsWith(u8, entry_name, "/")) {
            const dest_idx = c.zip_dir_add(dest_pex.handle, entry_name, 0);
            if (dest_idx < 0) {
                log.err(
                    "Failed to add directory entry {d} ({s}) to {s}: {s}",
                    .{ index, entry_name, dest_pex.path, c.zip_strerror(dest_pex.handle) },
                );
                return error.ZipEntryAddDirectoryError;
            }
            try setEntryMtime(dest_pex, @intCast(dest_idx), entry_name);
            continue;
        }

        const retain_original_compression = std.mem.eql(
            u8,
            "PEX-INFO",
            entry_name,
        ) or std.mem.endsWith(u8, entry_name, "/");

        const src = c.zip_source_zip_file(
            dest_pex.handle,
            source_pex.handle,
            @intCast(index),
            if (retain_original_compression) c.ZIP_FL_COMPRESSED else 0,
            0,
            -1,
            null,
        ) orelse {
            log.err(
                "Failed to open entry {d} ({s}) from {s}: {s}",
                .{ index, entry_name, source_pex.path, c.zip_strerror(dest_pex.handle) },
            );
            return error.ZipEntryOpenError;
        };
        errdefer c.zip_source_free(src);

        const dest_idx = c.zip_file_add(dest_pex.handle, entry_name, src, 0);
        if (dest_idx < 0) {
            log.err(
                "Failed to add file entry {d} ({s}) to {s}: {s}",
                .{ index, entry_name, dest_pex.path, c.zip_strerror(dest_pex.handle) },
            );
            return error.ZipEntryAddFileError;
        }
        try setEntryMtime(dest_pex, @intCast(dest_idx), entry_name);
        if (retain_original_compression) {
            continue;
        }

        const result = c.zip_set_file_compression(
            dest_pex.handle,
            @intCast(dest_idx),
            @intFromEnum(options.method),
            @intCast(options.level),
        );
        if (result < 0) {
            log.err(
                "Failed to set compression to zstd for entry {d} ({s}) in {s}: {s}",
                .{ index, entry_name, dest_pex.path, c.zip_strerror(dest_pex.handle) },
            );
            return error.ZipEntrySetCompressionZstdError;
        }
    }
}

fn embedLibs(pex: *Zip) !void {
    for (libs.keys(), libs.values()) |lib_rel_path, lib_data| {
        const src = c.zip_source_buffer(pex.handle, lib_data.ptr, lib_data.len, 0) orelse {
            log.err(
                "Failed to create a zip source buffer from embedded {s} to add to {s}: {s}",
                .{ lib_rel_path, pex.path, c.zip_strerror(pex.handle) },
            );
            return error.ZipEntryOpenMainError;
        };
        const dest_idx = c.zip_file_add(pex.handle, lib_rel_path.ptr, src, 0);
        if (dest_idx < 0) {
            log.err(
                "Failed to add {s} file entry to {s}: {s}",
                .{ lib_rel_path, pex.path, c.zip_strerror(pex.handle) },
            );
            return error.ZipEntryAddMainError;
        }
        try setEntryMtime(pex, @intCast(dest_idx), lib_rel_path);
    }
}

fn addEntryPoint(pex: *Zip, entry_point: [*c]const u8) !void {
    const src = c.zip_source_buffer(pex.handle, __main__.ptr, __main__.len, 0) orelse {
        log.err(
            "Failed to create a zip source buffer from __main__.py to add to {s}: {s}",
            .{ pex.path, c.zip_strerror(pex.handle) },
        );
        return error.ZipEntryOpenMainError;
    };
    const dest_idx = c.zip_file_add(pex.handle, entry_point, src, 0);
    if (dest_idx < 0) {
        log.err(
            "Failed to add {s} file entry to {s}: {s}",
            .{ entry_point, pex.path, c.zip_strerror(pex.handle) },
        );
        return error.ZipEntryAddMainError;
    }
    try setEntryMtime(pex, @intCast(dest_idx), std.mem.span(entry_point));
}

const ProgressContext = extern struct {
    progress: *std.Progress.Node,
    total_items: usize,
};

fn record_progress(_: ?*c.zip_t, progress: f64, user_data: ?*anyopaque) callconv(.c) void {
    const progress_ctx: *ProgressContext = @ptrCast(@alignCast(user_data.?));
    const total_items: f64 = @floatFromInt(progress_ctx.total_items);
    const completed: usize = @intFromFloat(@round(@max(0, @min(
        total_items,
        progress * total_items,
    ))));
    progress_ctx.progress.setCompletedItems(completed);
}

fn inject(
    allocator: std.mem.Allocator,
    pex_path: [*c]const u8,
) !void {
    var pex = try Zip.init(pex_path, .{});
    defer pex.deinit();

    const czex_path = res: {
        const pex_path_str = std.mem.span(pex_path);
        const path = try std.fmt.allocPrintZ(
            allocator,
            "{s}.czex",
            .{std.fs.path.stem(pex_path_str)},
        );
        if (std.fs.path.dirname(pex_path_str)) |dirname| {
            defer allocator.free(path);
            break :res try std.fs.path.joinZ(allocator, &.{ dirname, path });
        }
        break :res path;
    };
    defer allocator.free(czex_path);

    var czex = try Zip.init(czex_path, .{ .mode = .truncate });
    errdefer czex.deinit();

    const prefix_data: ?[]const u8 = try setZipPrefix(allocator, &pex, &czex);
    defer if (prefix_data) |data| allocator.free(data);

    try transferEntries(&pex, &czex, .{ .method = .zstd, .level = 3 });
    try embedLibs(&czex);
    try addEntryPoint(&czex, "__pex__/__init__.py");
    try addEntryPoint(&czex, "__main__.py");

    var root_progress = std.Progress.start(.{
        .refresh_rate_ns = 17 * std.time.ns_per_ms, // ~60Hz
        .root_name = "pexcz",
    });
    defer root_progress.end();
    var progress = root_progress.start("inject", pex.num_entries);
    defer progress.end();

    var progress_ctx: ProgressContext = .{ .progress = &progress, .total_items = pex.num_entries };
    const precision: f64 = 1.0 / @as(f64, @floatFromInt(pex.num_entries));
    _ = c.zip_register_progress_callback_with_state(
        czex.handle,
        precision,
        record_progress,
        null,
        &progress_ctx,
    );
    czex.deinit();

    var czex_file = try std.fs.cwd().openFileZ(czex.path, .{});
    defer czex_file.close();

    if (native_os != .windows) {
        const metadata = try czex_file.metadata();
        var permissions = metadata.permissions();
        permissions.inner.unixSet(.user, .{ .execute = true });
        permissions.inner.unixSet(.group, .{ .execute = true });
        permissions.inner.unixSet(.other, .{ .execute = true });
        try czex_file.setPermissions(permissions);
    }

    std.debug.print("Injected pexcz runtime for {s} in {s}\n", .{ pex_path, czex.path });
    // TODO(John Sirois): XXX: handle __pex__/ import hook
}

const BootResult = enum(c_int) {
    boot_error = 75,
    _,
};

pub fn main() !u8 {
    var alloc = Allocator.init();
    errdefer _ = alloc.deinit();
    const allocator = alloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const prog = args[0];
    var result: u8 = 0;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            help(prog);
            break;
        } else if (std.mem.eql(u8, "inject", arg)) {
            if (args.len <= i + 1) {
                result = usage(prog, "The inject subcommand requires a PEX file argument.");
                break;
            } else if (args.len > i + 2) {
                result = usage(
                    prog,
                    try std.fmt.allocPrint(
                        allocator,
                        \\The inject subcommand expects only a PEX file argument.
                        \\Given extra arguments: {s}
                    ,
                        .{try std.mem.join(allocator, " ", args[i + 2 ..])},
                    ),
                );
                break;
            }

            try inject(allocator, args[i + 1]);
            std.process.exit(0);
        } else {
            result = usage(
                prog,
                try std.fmt.allocPrint(allocator, "Unexpected argument: {s}", .{arg}),
            );
            break;
        }
    } else {
        help(prog);
    }
    if (alloc.deinit() != .ok) {
        return @intFromEnum(BootResult.boot_error);
    } else {
        return result;
    }
}

test "Export PEX env var" {
    const options = @import("options");

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_dir_path);

    var exe_py = try tmp_dir.dir.createFile("exe.py", .{});
    defer exe_py.close();

    var exe_py_fp = std.io.bufferedWriter(exe_py.writer());
    try exe_py_fp.writer().writeAll("import os; print(os.environ[\"PEX\"])");
    try exe_py_fp.flush();

    const create_pex_result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{
            "uv",
            "run",
            "pex",
            "--exe",
            "exe.py",
            "-o",
            "test.pex",
        },
        .cwd = tmp_dir_path,
        .cwd_dir = tmp_dir.dir,
    });
    defer std.testing.allocator.free(create_pex_result.stdout);
    defer std.testing.allocator.free(create_pex_result.stderr);
    try std.testing.expectEqualDeep(
        std.process.Child.Term{ .Exited = 0 },
        create_pex_result.term,
    );

    const execute_pex_result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "uv", "run", "python", "test.pex" },
        .cwd = tmp_dir_path,
        .cwd_dir = tmp_dir.dir,
        .max_output_bytes = 1024 * 1024,
    });
    defer std.testing.allocator.free(execute_pex_result.stdout);
    defer std.testing.allocator.free(execute_pex_result.stderr);
    try std.testing.expectEqualDeep(
        std.process.Child.Term{ .Exited = 0 },
        execute_pex_result.term,
    );

    const expected_pex_env_var_value = try tmp_dir.dir.realpathAlloc(
        std.testing.allocator,
        "test.pex",
    );
    defer std.testing.allocator.free(expected_pex_env_var_value);

    try std.testing.expectEqualStrings(
        expected_pex_env_var_value,
        std.mem.trimRight(u8, execute_pex_result.stdout, "\r\n"),
    );

    const create_czex_result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ options.pexcz_exe, "inject", "test.pex" },
        .cwd = tmp_dir_path,
        .cwd_dir = tmp_dir.dir,
    });
    defer std.testing.allocator.free(create_czex_result.stdout);
    defer std.testing.allocator.free(create_czex_result.stderr);
    try std.testing.expectEqualDeep(
        std.process.Child.Term{ .Exited = 0 },
        create_czex_result.term,
    );

    const execute_czex_result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "uv", "run", "python", "test.czex" },
        .cwd = tmp_dir_path,
        .cwd_dir = tmp_dir.dir,
        .max_output_bytes = 1024 * 1024,
    });
    defer std.testing.allocator.free(execute_czex_result.stdout);
    defer std.testing.allocator.free(execute_czex_result.stderr);
    try std.testing.expectEqualDeep(
        std.process.Child.Term{ .Exited = 0 },
        execute_czex_result.term,
    );

    const expected_czex_pex_env_var_value = try tmp_dir.dir.realpathAlloc(
        std.testing.allocator,
        "test.czex",
    );
    defer std.testing.allocator.free(expected_czex_pex_env_var_value);

    try std.testing.expectEqualStrings(
        expected_czex_pex_env_var_value,
        std.mem.trimRight(u8, execute_czex_result.stdout, "\r\n"),
    );
}
