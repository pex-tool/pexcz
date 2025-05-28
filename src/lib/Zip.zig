const std = @import("std");

pub const c = @cImport({
    @cInclude("zip.h");
});

const log = std.log.scoped(.zip);

inline fn logEnabled(level: std.log.Level) bool {
    return std.log.logEnabled(level, .zip);
}

pub const Compression = enum(c_int) {
    deflate = c.ZIP_CM_DEFAULT,
    store = c.ZIP_CM_STORE,
    zstd = c.ZIP_CM_ZSTD,
};

pub const OpenOptions = struct {
    pub const Mode = enum(c_int) {
        read_only = c.ZIP_RDONLY,
        write = c.ZIP_CREATE,
        truncate = c.ZIP_CREATE | c.ZIP_TRUNCATE,
    };

    mode: Mode = .read_only,
};

path: [*c]const u8,
handle: *c.zip_t,
num_entries: usize,

const Self = @This();

pub fn init(filename: [*c]const u8, options: Self.OpenOptions) !Self {
    var zip_errno: c_int = undefined;
    var zip_error: c.zip_error_t = undefined;
    const handle = c.zip_open(filename, @intFromEnum(options.mode), &zip_errno) orelse {
        c.zip_error_init_with_code(&zip_error, zip_errno);
        defer c.zip_error_fini(&zip_error);
        log.err(
            "Failed to open zip file {s}: {s}",
            .{ filename, c.zip_error_strerror(&zip_error) },
        );
        return error.ZipOpenError;
    };

    const num_entries = c.zip_get_num_entries(handle, 0);
    std.debug.assert(num_entries >= 0);
    if (num_entries > std.math.maxInt(usize)) {
        return error.ZipTooManyEntries;
    }

    return Self{
        .path = filename,
        .handle = handle,
        .num_entries = @intCast(num_entries),
    };
}

pub fn deinit(self: Self) void {
    const zip_errno = c.zip_close(self.handle);
    if (zip_errno != 0 and logEnabled(.warn)) {
        var zip_error: c.zip_error_t = undefined;
        c.zip_error_init_with_code(&zip_error, zip_errno);
        defer c.zip_error_fini(&zip_error);
        log.warn("Failed to close zip file: {s}", .{c.zip_error_strerror(&zip_error)});
    }
}

pub fn extractToSlice(
    self: *Self,
    allocator: std.mem.Allocator,
    name: [*c]const u8,
) !?[]const u8 {
    const index = c.zip_name_locate(self.handle, name, 0);
    if (index < 0) {
        return null;
    }
    var stat: c.zip_stat_t = undefined;
    if (0 == c.zip_stat_index(self.handle, @intCast(index), 0, &stat)) {
        if (stat.size > std.math.maxInt(usize)) {
            return error.ZipEntryToLarge;
        }
        const buffer = try allocator.alloc(u8, @intCast(stat.size));
        var out = std.io.fixedBufferStream(buffer);
        try self.extractIndexToWriter(@intCast(index), std.mem.span(name), out.writer());
        return buffer;
    } else {
        var buffer = std.ArrayList(u8).init(allocator);
        try self.extractIndexToWriter(@intCast(index), std.mem.span(name), buffer.writer());
        return try buffer.toOwnedSlice();
    }
}

pub fn extractToDir(self: *Self, name: [*c]const u8, dest_dir_path: []const u8) !void {
    const index = c.zip_name_locate(self.handle, name, 0);
    if (index < 0) {
        return error.ZipEntryNotFound;
    }
    return self.extractIndexToDir(@intCast(index), std.mem.span(name), dest_dir_path);
}

fn extractIndexToDir(
    self: *Self,
    index: c.zip_uint64_t,
    name: []const u8,
    dest_dir_path: []const u8,
) !void {
    var dest_dir = try std.fs.cwd().makeOpenPath(dest_dir_path, .{});
    defer dest_dir.close();

    if (std.mem.endsWith(u8, name, "/")) {
        return dest_dir.makePath(name[0 .. name.len - 1]);
    }

    if (std.fs.path.dirname(name)) |dirname| {
        try dest_dir.makePath(dirname);
    }

    var file = try dest_dir.createFile(name, .{});
    defer file.close();

    var buf_out = std.io.bufferedWriter(file.writer());
    try self.extractIndexToWriter(index, name, buf_out.writer());
    return buf_out.flush();
}

fn extractIndexToWriter(
    self: *Self,
    index: c.zip_uint64_t,
    name: []const u8,
    writer: anytype,
) !void {
    const zfh = c.zip_fopen_index(self.handle, index, 0) orelse {
        log.err(
            "Failed to open zip entry {d} ({s}) from {s}: {s}",
            .{ index, name, self.path, c.zip_strerror(self.handle) },
        );
        return error.ZipFileOpenError;
    };
    defer _ = c.zip_fclose(zfh);

    var read_buffer: [8 * 4096]u8 = undefined; // An ~87% compressed block will fit.
    while (true) {
        const read_amt = c.zip_fread(zfh, &read_buffer, read_buffer.len);
        if (read_amt < 0) {
            log.err(
                "Failed to read zip entry {d} ({s}) from {s}: {s}",
                .{ index, name, self.path, c.zip_file_strerror(zfh) },
            );
            return error.ZipFileReadError;
        }
        if (read_amt == 0) {
            break;
        }
        try writer.writeAll(read_buffer[0..@intCast(read_amt)]);
    }
}

pub fn extract(
    self: *Self,
    dest_dir_path: []const u8,
    context: anytype,
    comptime shouldExtractFn: fn (context: @TypeOf(context), entry_name: []const u8) bool,
) !void {
    if (self.num_entries < 1) {
        return;
    }

    var dest_dir = try std.fs.cwd().makeOpenPath(dest_dir_path, .{});
    defer dest_dir.close();

    for (0..@intCast(self.num_entries)) |zip_idx| {
        const entry_name = std.mem.span(c.zip_get_name(self.handle, @intCast(zip_idx), 0) orelse {
            log.err("Failed to get name of entry {d} from {s}.", .{ zip_idx, self.path });
            return error.ZipEntryMetadataError;
        });
        if (shouldExtractFn(context, entry_name)) {
            if (std.mem.endsWith(u8, entry_name, "/")) {
                try dest_dir.makePath(entry_name[0 .. entry_name.len - 1]);
                continue;
            }

            if (std.fs.path.dirname(entry_name)) |dirname| {
                try dest_dir.makePath(dirname);
            }

            var file = try dest_dir.createFile(entry_name, .{});
            defer file.close();

            var buf_out = std.io.bufferedWriter(file.writer());
            try self.extractIndexToWriter(zip_idx, entry_name, buf_out.writer());
            try buf_out.flush();
        }
    }
}

const ParallelExtractOptions = struct {
    num_threads: ?usize = null,
};

const ErrInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

const ParallelExtractor = struct {
    errored: *std.atomic.Value(ErrInt),
    zips: []Self,
    dest_dir: []const u8,

    fn extract(
        id: usize,
        self: *ParallelExtractor,
        entry_index: usize,
        entry_name: []const u8,
    ) void {
        if (self.errored.load(.seq_cst) > 0) {
            return;
        }
        var zip = self.zips[id];
        return zip.extractIndexToDir(entry_index, entry_name, self.dest_dir) catch |err| {
            self.errored.store(@intFromError(err), .seq_cst);
            log.err(
                "Failed to extract zip entry {s} from {s}: {}",
                .{ entry_name, zip.path, err },
            );
        };
    }
};

pub fn parallelExtract(
    self: *Self,
    allocator: std.mem.Allocator,
    dest_dir_path: []const u8,
    context: anytype,
    comptime shouldExtractFn: fn (context: @TypeOf(context), entry_name: []const u8) bool,
    options: ParallelExtractOptions,
) !void {
    if (self.num_entries < 1) {
        return;
    }

    const num_threads = options.num_threads orelse @min(
        self.num_entries,
        std.Thread.getCpuCount() catch 1,
    );

    if (num_threads < 2) {
        return try self.extract(
            dest_dir_path,
            context,
            shouldExtractFn,
        );
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = num_threads, .track_ids = true });
    defer pool.deinit();

    var zips = try std.ArrayList(Self).initCapacity(allocator, pool.getIdCount());
    defer {
        for (zips.items) |z| {
            z.deinit();
        }
        zips.deinit();
    }
    for (0..pool.getIdCount()) |_| {
        try zips.append(try Self.init(self.path, .{ .mode = .read_only }));
    }

    var worker_err = std.atomic.Value(ErrInt).init(0);
    var extractor: ParallelExtractor = .{ .errored = &worker_err, .zips = zips.items, .dest_dir = dest_dir_path };

    var wg = std.Thread.WaitGroup{};
    for (0..@intCast(self.num_entries)) |zip_idx| {
        const err_int = worker_err.load(.seq_cst);
        if (err_int > 0) {
            return @errorFromInt(err_int);
        }
        const entry_name = std.mem.span(c.zip_get_name(
            self.handle,
            @intCast(zip_idx),
            0,
        ) orelse {
            log.err("Failed to get name of entry {d} from {s}.", .{ zip_idx, self.path });
            return error.ZipEntryMetadataError;
        });
        if (shouldExtractFn(context, entry_name)) {
            pool.spawnWgId(
                &wg,
                ParallelExtractor.extract,
                .{ &extractor, zip_idx, entry_name },
            );
        }
    }
    pool.waitAndWork(&wg);
    const err_int = worker_err.load(.seq_cst);
    if (err_int > 0) {
        return @errorFromInt(err_int);
    }
}
