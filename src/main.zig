const std = @import("std");

const pexcz = @import("pexcz");
const Allocator = pexcz.Allocator;
const Zip = pexcz.Zip;
const c = Zip.c;

const log = std.log.scoped(.pexcz);

fn help(prog: []const u8) noreturn {
    std.debug.print(
        \\Usage: {s} --help | inject <PEX> [-P <PATH>]
        \\
        \\ inject:  Inject a pexcz bootstrap in the given PEX file.
        \\
        \\Inject Options:
        \\ -P, --pexcz-python-package-root:  The path where the pexcz Python package to inject can
        \\                                   be found.
        \\General Options:
        \\ -h, --help:  Print this help and exit.
        \\
    ,
        .{prog},
    );
    std.process.exit(0);
}

fn usage(prog: []u8, message: []const u8) noreturn {
    std.debug.print(
        \\Usage: {s} --help | inject <PEX> [-P <PATH>]
        \\
        \\{s}
    ,
        .{ prog, message },
    );
    std.process.exit(1);
}

const CompressionOptions = struct {
    method: Zip.Compression = .deflate,
    level: i8 = 0,
};

fn transferEntries(
    source_pex: *Zip,
    dest_pex_path: [*c]const u8,
    options: CompressionOptions,
) !Zip {
    var dest_pex = try Zip.init(dest_pex_path, .{ .mode = .truncate });
    errdefer dest_pex.deinit();

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
            const dest_idx = c.zip_add_dir(dest_pex.handle, entry_name);
            if (dest_idx < 0) {
                log.err(
                    "Failed to add directory entry {d} ({s}) to {s}: {s}",
                    .{ index, entry_name, dest_pex.path, c.zip_strerror(dest_pex.handle) },
                );
                return error.ZipEntryAddDirectoryError;
            }
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
    return dest_pex;
}

fn inject(
    allocator: std.mem.Allocator,
    pex_path: [*c]const u8,
    pexcz_python_pkg_root: ?[]const u8,
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

    const czex = try transferEntries(&pex, czex_path, .{ .method = .zstd, .level = 3 });
    defer czex.deinit();
    std.debug.print("Injected pexcz runtime for {s} in {s}\n", .{ pex_path, czex.path });
    std.debug.print("TODO: XXX: actually inject a pexcz bootstrap in: {s}\n", .{czex_path});
    _ = pexcz_python_pkg_root;
    // 4. write __main__.py
    // 5. write .bootstrap/
    // 6. TODO(John Sirois): XXX: handle __pex__/ import hook
}

pub fn main() !void {
    var alloc = Allocator.init();
    defer alloc.deinit();
    const allocator = alloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const prog = args[0];
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            help(prog);
        } else if (std.mem.eql(u8, "inject", arg)) {
            const pexcz_python_package_root: ?[]const u8 = null;
            if (args.len <= i + 1) {
                usage(prog, "The inject subcommand requires a PEX file argument.");
            } else if (args.len > i + 2) {
                usage(
                    prog,
                    try std.fmt.allocPrint(
                        allocator,
                        \\The inject subcommand expects only a PEX file argument.
                        \\Given extra arguments: {s}
                    ,
                        .{try std.mem.join(allocator, " ", args[i + 2 ..])},
                    ),
                );
            }
            if (pexcz_python_package_root) |pppr| {
                try inject(allocator, args[i + 1], pppr);
                std.process.exit(0);
            } else {
                try inject(allocator, args[i + 1], null);
                std.process.exit(0);
                // usage(prog, "");
            }
        } else {
            usage(prog, try std.fmt.allocPrint(allocator, "Unexpected argument: {s}", .{arg}));
        }
    } else {
        help(prog);
    }
}
