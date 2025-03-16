const std = @import("std");

pub fn Zip(comptime SeekableZipStream: type) type {
    return struct {
        const ZipIterator = std.zip.Iterator(SeekableZipStream);
        const ZipEntry = ZipIterator.Entry;

        pub const Entry = struct {
            name: []const u8,
            entry: ZipEntry,

            pub fn extract(self: @This(), zip_path: []const u8, dest_dir_path: []const u8) !void {
                var zip_file = try std.fs.cwd().openFile(zip_path, .{});
                defer zip_file.close();
                return self.extract_to_dir(zip_file, dest_dir_path);
            }

            pub fn extractZ(self: @This(), zip_path: [*:0]const u8, dest_dir_path: []const u8) !void {
                var zip_file = try std.fs.cwd().openFileZ(zip_path, .{});
                defer zip_file.close();
                return self.extract_to_dir(zip_file, dest_dir_path);
            }

            fn extract_to_dir(self: @This(), zip_file: std.fs.File, dest_dir_path: []const u8) !void {
                var dest_dir = try std.fs.cwd().openDir(dest_dir_path, .{});
                defer dest_dir.close();
                return self.extract_from_stream(zip_file.seekableStream(), dest_dir);
            }

            pub fn extract_from_stream(self: @This(), stream: SeekableZipStream, dest_dir: std.fs.Dir) !void {
                var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
                const crc32 = try self.entry.extract(stream, .{}, &filename_buf, dest_dir);
                std.debug.assert(crc32 == self.entry.crc32);
            }
        };

        const EntryMap = std.StringArrayHashMapUnmanaged(Entry);

        entries_by_name: EntryMap,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, seekable_zip_stream: SeekableZipStream) !Self {
            var entries_by_name = std.StringArrayHashMapUnmanaged(Entry){};
            var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
            var zip_iter = try ZipIterator.init(seekable_zip_stream);
            while (try zip_iter.next()) |zip_entry| {
                const filename = res: {
                    const filename_slice = filename_buf[0..zip_entry.filename_len];
                    const read = try seekable_zip_stream.context.readAll(filename_slice);
                    std.debug.assert(read == zip_entry.filename_len);
                    const filename = try allocator.alloc(u8, filename_slice.len);
                    @memcpy(filename, filename_slice);
                    break :res filename;
                };
                try entries_by_name.put(allocator, filename, Entry{ .name = filename, .entry = zip_entry });
            }
            return .{ .entries_by_name = entries_by_name };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.entries_by_name.keys()) |key| {
                // N.B.: The map values share the key; so this free covers both.
                allocator.free(key);
            }
            self.entries_by_name.deinit(allocator);
        }

        pub fn entry(self: Self, name: []const u8) ?Entry {
            return self.entries_by_name.get(name);
        }

        pub fn entries(self: Self) []const Entry {
            return self.entries_by_name.values();
        }
    };
}
