const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("zip.h");
});
const Zip = @import("zip").Zip;

fn read_pex_info(pex: [*c]const u8) !void {
    const zip = try Zip.init(pex, .{ .mode = .read_only });
    defer zip.deinit();

    const zfh = c.zip_fopen(zip.handle, "PEX-INFO", 0) orelse {
        std.debug.print("PEX {s} is missing PEX-INFO.\n", .{pex});
        return error.ZipFileOpenError;
    };
    defer _ = c.zip_fclose(zfh);

    var out = std.io.getStdOut().writer();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_amt = c.zip_fread(zfh, &buffer, buffer.len);
        if (read_amt < 0) {
            std.debug.print("Failed to read PEX-INFO from {s}.\n", .{pex});
            return error.ZipFileReadError;
        }
        if (read_amt == 0) {
            break;
        }
        try out.writeAll(buffer[0..@intCast(read_amt)]);
    }
    try out.writeByte('\n');
}

fn extract_zip(allocator: std.mem.Allocator, path: [*c]const u8) !void {
    const zip = try Zip.init(path, .{ .mode = .read_only });
    defer zip.deinit();

    const entry_count = c.zip_get_num_entries(zip.handle, 0);
    if (entry_count < 0) {
        std.debug.print("Zip {s} has no entries!\n", .{path});
        return error.ZipEmptyError;
    }

    const dest_dir_path = try std.fs.path.join(allocator, &.{ "/tmp", std.mem.span(path) });
    defer allocator.free(dest_dir_path);
    var dest_dir = try std.fs.cwd().makeOpenPath(dest_dir_path, .{});
    defer dest_dir.close();

    for (0..@intCast(entry_count)) |index| {
        const entry_name = std.mem.span(c.zip_get_name(zip.handle, @intCast(index), 0) orelse {
            std.debug.print("Failed to get name of entry {d} from {s}.\n", .{ index, path });
            return error.ZipEntryMetadataError;
        });
        if ('/' == entry_name[entry_name.len - 1]) {
            try dest_dir.makePath(entry_name[0 .. entry_name.len - 1]);
            continue;
        } else if (std.fs.path.dirname(entry_name)) |dir_name| {
            try dest_dir.makePath(dir_name);
        }

        const zfh = c.zip_fopen_index(zip.handle, @intCast(index), 0) orelse {
            std.debug.print("Failed to open zip entry {d} ({s}) from {s}.\n", .{ index, entry_name, path });
            return error.ZipFileOpenError;
        };
        defer _ = c.zip_fclose(zfh);

        var file = try dest_dir.createFile(entry_name, .{});
        defer file.close();

        var buf_out = std.io.bufferedWriter(file.writer());
        var out = buf_out.writer();
        var read_buffer: [8 * 4096]u8 = undefined; // An ~87% compressed block will fit.
        while (true) {
            const read_amt = c.zip_fread(zfh, &read_buffer, read_buffer.len);
            if (read_amt < 0) {
                std.debug.print(
                    "Failed to read zip entry {d} ({s}) from {s}.\n",
                    .{ index, entry_name, path },
                );
                return error.ZipFileReadError;
            }
            if (read_amt == 0) {
                break;
            }
            try out.writeAll(read_buffer[0..@intCast(read_amt)]);
        }
    }
}

fn extract_entry(
    index: usize,
    entry_name: []const u8,
    zip_path: [*c]const u8,
    zip: *const Zip,
    dest_dir_path: []const u8,
) !void {
    var dest_dir = try std.fs.cwd().makeOpenPath(dest_dir_path, .{});
    defer dest_dir.close();

    if (std.fs.path.dirname(entry_name)) |dir_name| {
        try dest_dir.makePath(dir_name);
    }

    const zfh = c.zip_fopen_index(zip.handle, @intCast(index), 0) orelse {
        std.debug.print(
            "Failed to open zip entry {d} ({s}) from {s}: {s}\n",
            .{ index, entry_name, zip_path, c.zip_strerror(zip.handle) },
        );
        return error.ZipFileOpenError;
    };
    defer _ = c.zip_fclose(zfh);

    var file = try dest_dir.createFile(entry_name, .{});
    defer file.close();

    var buf_out = std.io.bufferedWriter(file.writer());
    var out = buf_out.writer();
    var read_buffer: [8 * 4096]u8 = undefined; // An ~87% compressed block will fit.
    while (true) {
        const read_amt = c.zip_fread(zfh, &read_buffer, read_buffer.len);
        if (read_amt < 0) {
            std.debug.print(
                "Failed to read zip entry {d} ({s}) from {s}: {s}\n",
                .{ index, entry_name, zip_path, c.zip_file_strerror(zfh) },
            );
            return error.ZipFileReadError;
        }
        if (read_amt == 0) {
            break;
        }
        try out.writeAll(read_buffer[0..@intCast(read_amt)]);
    }
}

fn extract_zip_parallel(allocator: std.mem.Allocator, path: [*c]const u8) !void {
    const zip = try Zip.init(path, .{ .mode = .read_only });
    defer zip.deinit();

    const entry_count = c.zip_get_num_entries(zip.handle, 0);
    if (entry_count < 0) {
        std.debug.print("Zip {s} has no entries!\n", .{path});
        return error.ZipEmptyError;
    }

    const dest_dir_path = try std.fs.path.join(
        allocator,
        &.{ "/tmp", "parallel", std.mem.span(path) },
    );
    defer allocator.free(dest_dir_path);

    var pool: std.Thread.Pool = undefined;
    const num_entries: usize = @intCast(entry_count);
    try pool.init(
        .{
            .allocator = allocator,
            .n_jobs = @min(num_entries, std.Thread.getCpuCount() catch 1),
            .track_ids = true,
        },
    );
    defer pool.deinit();

    var zips = try std.ArrayList(Zip).initCapacity(allocator, pool.getIdCount());
    defer {
        for (zips.items) |z| {
            z.deinit();
        }
        zips.deinit();
    }
    for (0..pool.getIdCount()) |_| {
        try zips.append(try Zip.init(path, .{ .mode = .read_only }));
    }

    const ParallelZip = struct {
        alloc: std.mem.Allocator,
        zips: []Zip,
        zip_path: [*c]const u8,
        dest_dir: []const u8,

        fn extract(
            id: usize,
            self: *@This(),
            index: usize,
            entry_name: []const u8,
        ) void {
            defer self.alloc.free(entry_name);
            return extract_entry(
                index,
                entry_name,
                self.zip_path,
                &self.zips[id],
                self.dest_dir,
            ) catch {
                // std.debug.print(
                //     "Failed to extract zip entry {s} from {s}: {}\n",
                //     .{ entry_name, self.zip_path, err },
                // );
            };
        }
    };

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    var pz: ParallelZip = .{
        .alloc = thread_safe_alloc.allocator(),
        .zips = zips.items,
        .zip_path = path,
        .dest_dir = dest_dir_path,
    };

    var wg = std.Thread.WaitGroup{};
    for (0..@intCast(entry_count)) |index| {
        const entry_name = std.mem.span(c.zip_get_name(zip.handle, @intCast(index), 0) orelse {
            std.debug.print("Failed to get name of entry {d} from {s}.\n", .{ index, path });
            return error.ZipEntryMetadataError;
        });
        if ('/' == entry_name[entry_name.len - 1]) {
            continue;
        }
        pool.spawnWgId(&wg, ParallelZip.extract, .{ &pz, index, try allocator.dupe(u8, entry_name) });
    }
    pool.waitAndWork(&wg);
}

fn write_zstd_zip(source_zip_path: [*c]const u8, compression_level: c.zip_uint32_t) ![*c]const u8 {
    const source_zip = try Zip.init(source_zip_path, .{ .mode = .read_only });
    defer source_zip.deinit();

    const dest_zip_path: [*c]const u8 = "future.pex";
    const dest_zip = try Zip.init(dest_zip_path, .{ .mode = .truncate });
    defer dest_zip.deinit();

    const entry_count = c.zip_get_num_entries(source_zip.handle, 0);
    if (entry_count < 0) {
        std.debug.print("Zip {s} has no entries!\n", .{source_zip_path});
        return error.ZipEmptyError;
    }
    for (0..@intCast(entry_count)) |index| {
        const entry_name = std.mem.span(c.zip_get_name(source_zip.handle, @intCast(index), 0) orelse {
            std.debug.print("Failed to get name of entry {d} from {s}.\n", .{ index, source_zip_path });
            return error.ZipEntryMetadataError;
        });
        const src = c.zip_source_zip_file(
            dest_zip.handle,
            source_zip.handle,
            @intCast(index),
            0,
            0,
            -1,
            null,
        ) orelse {
            var zip_error = c.zip_get_error(dest_zip.handle).*;
            std.debug.print(
                "Failed to open entry {d} ({s}) from {s}: {s}\n",
                .{ index, entry_name, source_zip_path, c.zip_error_strerror(&zip_error) },
            );
            return error.ZipEntryOpenError;
        };
        const dest_idx = c.zip_file_add(dest_zip.handle, entry_name, src, 0);
        if (dest_idx < 0) {
            var zip_error = c.zip_get_error(dest_zip.handle).*;
            std.debug.print(
                "Failed to add file entry {d} ({s}) to {s}: {s}\n",
                .{ index, entry_name, dest_zip_path, c.zip_error_strerror(&zip_error) },
            );
            return error.ZipEntryAddFileError;
        }
        if (std.mem.eql(u8, "__main__.py", entry_name) or std.mem.eql(u8, "PEX-INFO", entry_name)) {
            continue;
        }
        const result = c.zip_set_file_compression(
            dest_zip.handle,
            @intCast(dest_idx),
            c.ZIP_CM_ZSTD,
            compression_level,
        );
        if (result < 0) {
            var zip_error = c.zip_get_error(dest_zip.handle).*;
            std.debug.print(
                "Failed to set compression to zstd for entry {d} ({s}) in {s}: {s}\n",
                .{ index, entry_name, dest_zip_path, c.zip_error_strerror(&zip_error) },
            );
            return error.ZipEntrySetCompressionZstdError;
        }
    }
    return dest_zip_path;
}

const Debug = struct {
    const DebugAllocator = std.heap.DebugAllocator(
        .{ .safety = true, .verbose_log = true, .enable_memory_limit = true },
    );

    debug_allocator: DebugAllocator,

    const Self = @This();

    pub fn init() Self {
        return .{ .debug_allocator = DebugAllocator.init };
    }

    pub fn deinit(self: *Self) void {
        const check = self.debug_allocator.deinit();
        std.debug.assert(check == .ok);
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.debug_allocator.allocator();
    }

    pub fn bytes_used(self: Self) usize {
        return self.debug_allocator.total_requested_bytes;
    }
};

const Arena = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init() Self {
        return .{ .arena = std.heap.ArenaAllocator.init(
            if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator,
        ) };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn bytes_used(self: Self) usize {
        return self.arena.queryCapacity();
    }
};

const Allocator = switch (builtin.mode) {
    .Debug => Debug,
    else => Arena,
};

pub fn main() !void {
    var allocator = Allocator.init();
    defer allocator.deinit();

    try std.fs.cwd().deleteTree("/tmp/cowsay.pex");
    try std.fs.cwd().deleteTree("/tmp/parallel/cowsay.pex");
    try std.fs.cwd().deleteTree("/tmp/future.pex");
    try std.fs.cwd().deleteTree("/tmp/parallel/future.pex");

    var timer = try std.time.Timer.start();
    try read_pex_info("cowsay.pex");
    std.debug.print("Read PEX-INFO took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    try extract_zip_parallel(allocator.allocator(), "cowsay.pex");
    std.debug.print("Extract PEX parallel took {d:.3}ms.\n", .{timer.lap() / 1_000_000});
    try extract_zip(allocator.allocator(), "cowsay.pex");
    std.debug.print("Extract PEX took {d:.3}ms.\n", .{timer.lap() / 1_000_000});

    const zstd_zip = try write_zstd_zip("cowsay.pex", 3);
    std.debug.print(
        "Create zstd PEX from normal PEX took {d:.3}ms.\n",
        .{timer.lap() / 1_000_000},
    );

    try extract_zip(allocator.allocator(), zstd_zip);
    std.debug.print("Extract zstd PEX took {d:.3}ms.\n", .{timer.lap() / 1_000_000});
    try extract_zip_parallel(allocator.allocator(), zstd_zip);
    std.debug.print("Extract zstd PEX parallel took {d:.3}ms.\n", .{timer.lap() / 1_000_000});
}
