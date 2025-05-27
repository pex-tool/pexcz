const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("zip.h");
});
const pexcz = @import("pexcz");
const Allocator = pexcz.Allocator;
const Zip = pexcz.Zip;

fn write_zstd_zip(source_zip: *Zip, compression_level: c.zip_uint32_t) !Zip {
    const dest_zip_path: [*c]const u8 = "future.pex";
    const dest_zip = try Zip.init(dest_zip_path, .{ .mode = .truncate });
    errdefer dest_zip.deinit();

    for (0..source_zip.num_entries) |index| {
        const entry_name = std.mem.span(c.zip_get_name(
            source_zip.handle,
            @intCast(index),
            0,
        ) orelse {
            std.debug.print(
                "Failed to get name of entry {d} from {s}.\n",
                .{ index, source_zip.path },
            );
            return error.ZipEntryMetadataError;
        });
        const src = c.zip_source_zip_file(
            dest_zip.handle,
            source_zip.handle,
            @intCast(index),
            c.ZIP_FL_UNCHANGED,
            0,
            -1,
            null,
        ) orelse {
            std.debug.print(
                "Failed to open entry {d} ({s}) from {s}: {s}\n",
                .{ index, entry_name, source_zip.path, c.zip_strerror(dest_zip.handle) },
            );
            return error.ZipEntryOpenError;
        };
        errdefer c.zip_source_free(src);
        const dest_idx = c.zip_file_add(dest_zip.handle, entry_name, src, 0);
        if (dest_idx < 0) {
            std.debug.print(
                "Failed to add file entry {d} ({s}) to {s}: {s}\n",
                .{ index, entry_name, dest_zip_path, c.zip_strerror(dest_zip.handle) },
            );
            return error.ZipEntryAddFileError;
        }
        if (std.mem.eql(u8, "__main__.py", entry_name) or std.mem.eql(
            u8,
            "PEX-INFO",
            entry_name,
        ) or std.mem.endsWith(u8, entry_name, "/")) {
            continue;
        }
        const result = c.zip_set_file_compression(
            dest_zip.handle,
            @intCast(dest_idx),
            c.ZIP_CM_ZSTD,
            compression_level,
        );
        if (result < 0) {
            std.debug.print(
                "Failed to set compression to zstd for entry {d} ({s}) in {s}: {s}\n",
                .{ index, entry_name, dest_zip_path, c.zip_strerror(dest_zip.handle) },
            );
            return error.ZipEntrySetCompressionZstdError;
        }
    }
    dest_zip.deinit();
    return try Zip.init(dest_zip_path, .{});
}

pub fn main() !void {
    var allocator = Allocator.init();
    defer allocator.deinit();

    const alloc = allocator.allocator();

    for (@as(
        []const []const u8,
        &.{
            "/tmp/cowsay.pex",
            "/tmp/parallel/cowsay.pex",
            "/tmp/future.pex",
            "/tmp/parallel/future.pex",
        },
    )) |path| {
        std.fs.cwd().deleteTree(path) catch {};
    }

    const SkipExtractDirs = struct {
        pub fn should_extract(_: void, name: []const u8) bool {
            return name.len == 0 or '/' != name[name.len - 1];
        }
    };

    var timer = try std.time.Timer.start();

    var cowsay_zip = try Zip.init("cowsay.pex", .{});
    defer cowsay_zip.deinit();

    if (try cowsay_zip.extract_to_slice(alloc, "PEX-INFO")) |pex_info| {
        defer alloc.free(pex_info);
        std.debug.print("{s}\n", .{pex_info});
        std.debug.print("Read PEX-INFO took {d:.3}ms.\n", .{timer.lap() / 1_000_000});
    } else {
        std.debug.print("Failed to find PEX-INFO in {s}!", .{cowsay_zip.path});
    }

    try cowsay_zip.parallel_extract(
        alloc,
        "/tmp/parallel/cowsay.pex",
        {},
        SkipExtractDirs.should_extract,
        .{},
    );
    std.debug.print("Extract PEX parallel took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    try cowsay_zip.extract("/tmp/cowsay.pex", {}, SkipExtractDirs.should_extract);
    std.debug.print("Extract PEX took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    var zstd_zip = try write_zstd_zip(&cowsay_zip, 3);
    defer zstd_zip.deinit();
    std.debug.print(
        "Create zstd PEX from normal PEX took {d:.3}ms.\n",
        .{timer.lap() / 1_000_000},
    );

    try zstd_zip.extract("/tmp/future.pex", {}, SkipExtractDirs.should_extract);
    std.debug.print("Extract zstd PEX took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    try zstd_zip.parallel_extract(
        alloc,
        "/tmp/parallel/future.pex",
        {},
        SkipExtractDirs.should_extract,
        .{},
    );
    std.debug.print("Extract zstd PEX parallel took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    std.debug.print("Used {d} bytes.\n", .{allocator.bytes_used()});
}
