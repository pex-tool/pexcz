const std = @import("std");

const pexcz = @import("pexcz");

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

fn inject(
    allocator: std.mem.Allocator,
    pex: []const u8,
    pexcz_python_pkg_root: ?[]const u8,
) !void {
    var zip_file = try std.fs.cwd().openFile(pex, .{});
    defer zip_file.close();
    const zip_stream = zip_file.seekableStream();
    const zip = try pexcz.ZipFile.init(allocator, zip_stream);
    const zip_entries = zip.entries();

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(
        &pool,
        .{
            .allocator = allocator,
            .n_jobs = @min(zip_entries.len, std.Thread.getCpuCount() catch 1),
        },
    );
    defer pool.deinit();

    const Zip = struct {
        fn extract(
            entry: pexcz.ZipFile.Entry,
            zip_path: []const u8,
            dest_dir_path: []const u8,
        ) void {
            return entry.extract(zip_path, dest_dir_path) catch |err| {
                std.debug.print(
                    "Failed to extract zip entry {s} from {s}: {}\n",
                    .{ entry.name, zip_path, err },
                );
            };
        }
    };

    var temp_dirs = pexcz.fs.TempDirs.init(allocator);
    defer temp_dirs.deinit();
    const temp_path = try temp_dirs.mkdtemp(false);
    var wg = std.Thread.WaitGroup{};
    next_entry: for (zip_entries) |zip_entry| {
        for ([_][]const u8{ "__main__.py", ".bootstrap/", "__pex__/" }) |name| {
            if (std.mem.eql(u8, name, zip_entry.name)) {
                continue :next_entry;
            }
        }
        for ([_][]const u8{ ".bootstrap/", "__pex__/" }) |name| {
            if (std.mem.startsWith(u8, zip_entry.name, name)) {
                continue :next_entry;
            }
        }
        pool.spawnWg(&wg, Zip.extract, .{ zip_entry, pex, temp_path });
    }
    wg.wait();
    std.debug.print("Extracted {s} to {s}\n", .{ pex, temp_path });
    std.debug.print("TODO: XXX: inject a pexcz bootstrap in: {s}\n", .{pex});
    _ = pexcz_python_pkg_root;
    // 4. write __main__.py
    // 5. write .bootstrap/
    // 6. TODO(John Sirois): XXX: handle __pex__/ import hook
}

pub fn main() !void {
    var alloc = pexcz.Allocator.init();
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
