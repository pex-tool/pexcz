const std = @import("std");

pub fn Zip(comptime SeekableZipStream: type) type {
    return struct {
        pub const SeekableStream = SeekableZipStream;
        const ZipIterator = std.zip.Iterator(SeekableStream);
        const ZipEntry = ZipIterator.Entry;

        pub const Entry = struct {
            allocator: std.mem.Allocator,
            name: []const u8,
            entry: ZipEntry,

            fn from(
                allocator: std.mem.Allocator,
                zip_stream: SeekableStream,
                zip_entry: ZipEntry,
            ) !@This() {
                const filename = res: {
                    const filename = try allocator.alloc(u8, zip_entry.filename_len);
                    const read = try zip_stream.context.readAll(filename);
                    std.debug.assert(read == zip_entry.filename_len);
                    break :res filename;
                };
                return .{ .allocator = allocator, .name = filename, .entry = zip_entry };
            }

            pub fn deinit(self: @This()) void {
                self.allocator.free(self.name);
            }

            pub fn extract(self: @This(), zip_path: []const u8, dest_dir_path: []const u8) !void {
                var zip_file = try std.fs.cwd().openFile(zip_path, .{});
                defer zip_file.close();

                var dest_dir = try std.fs.cwd().openDir(dest_dir_path, .{});
                defer dest_dir.close();
                return self.extract_from_stream(zip_file.seekableStream(), dest_dir);
            }

            pub fn extract_from_stream(
                self: @This(),
                stream: SeekableZipStream,
                dest_dir: std.fs.Dir,
            ) !void {
                var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
                const crc32 = try self.entry.extract(stream, .{}, &filename_buf, dest_dir);
                std.debug.assert(crc32 == self.entry.crc32);
            }

            fn isMaxInt(uint: anytype) bool {
                return uint == std.math.maxInt(@TypeOf(uint));
            }

            const FileExtents = struct {
                uncompressed_size: u64,
                compressed_size: u64,
                local_file_header_offset: u64,
            };

            fn readZip64FileExtents(
                comptime T: type,
                header: T,
                extents: *FileExtents,
                data: []u8,
            ) !void {
                var data_offset: usize = 0;
                if (isMaxInt(header.uncompressed_size)) {
                    if (data_offset + 8 > data.len)
                        return error.ZipBadCd64Size;
                    extents.uncompressed_size = std.mem.readInt(
                        u64,
                        data[data_offset..][0..8],
                        .little,
                    );
                    data_offset += 8;
                }
                if (isMaxInt(header.compressed_size)) {
                    if (data_offset + 8 > data.len)
                        return error.ZipBadCd64Size;
                    extents.compressed_size = std.mem.readInt(
                        u64,
                        data[data_offset..][0..8],
                        .little,
                    );
                    data_offset += 8;
                }

                switch (T) {
                    std.zip.CentralDirectoryFileHeader => {
                        if (isMaxInt(header.local_file_header_offset)) {
                            if (data_offset + 8 > data.len)
                                return error.ZipBadCd64Size;
                            extents.local_file_header_offset = std.mem.readInt(
                                u64,
                                data[data_offset..][0..8],
                                .little,
                            );
                            data_offset += 8;
                        }
                        if (isMaxInt(header.disk_number)) {
                            if (data_offset + 4 > data.len)
                                return error.ZipInvalid;
                            const disk_number = std.mem.readInt(
                                u32,
                                data[data_offset..][0..4],
                                .little,
                            );
                            if (disk_number != 0)
                                return error.ZipMultiDiskUnsupported;
                            data_offset += 4;
                        }
                        if (data_offset > data.len)
                            return error.ZipBadCd64Size;
                    },
                    else => {},
                }
            }

            pub fn extract_to_slice(
                self: @This(),
                allocator: std.mem.Allocator,
                stream: SeekableStream,
            ) ![]const u8 {
                const buffer = try allocator.alloc(
                    u8,
                    // N.B.: Guarded at function entrance with a check and early error.
                    @intCast(self.entry.uncompressed_size),
                );
                errdefer allocator.free(buffer);
                var writer = std.io.fixedBufferStream(buffer);
                try self.extract_to_writer(stream, writer.writer());
                return buffer;
            }

            pub fn extract_to_writer(self: @This(), stream: SeekableStream, writer: anytype) !void {
                if (self.entry.uncompressed_size > std.math.maxInt(usize)) {
                    return error.EntryTooBig;
                }

                const local_data_header_offset: u64 = res: {
                    const local_header = blk: {
                        try stream.seekTo(self.entry.file_offset);
                        break :blk try stream.context.reader().readStructEndian(
                            std.zip.LocalFileHeader,
                            .little,
                        );
                    };
                    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
                        return error.ZipBadFileOffset;
                    if (local_header.version_needed_to_extract != self.entry.version_needed_to_extract)
                        return error.ZipMismatchVersionNeeded;
                    if (local_header.last_modification_time != self.entry.last_modification_time)
                        return error.ZipMismatchModTime;
                    if (local_header.last_modification_date != self.entry.last_modification_date)
                        return error.ZipMismatchModDate;

                    if (@as(u16, @bitCast(local_header.flags)) != @as(
                        u16,
                        @bitCast(self.entry.flags),
                    ))
                        return error.ZipMismatchFlags;
                    if (local_header.crc32 != 0 and local_header.crc32 != self.entry.crc32)
                        return error.ZipMismatchCrc32;

                    var extents: FileExtents = .{
                        .uncompressed_size = local_header.uncompressed_size,
                        .compressed_size = local_header.compressed_size,
                        .local_file_header_offset = 0,
                    };
                    if (local_header.extra_len > 0) {
                        var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
                        const extra = extra_buf[0..local_header.extra_len];

                        {
                            try stream.seekTo(
                                self.entry.file_offset + @sizeOf(
                                    std.zip.LocalFileHeader,
                                ) + local_header.filename_len,
                            );
                            const len = try stream.context.reader().readAll(extra);
                            if (len != extra.len)
                                return error.ZipTruncated;
                        }

                        var extra_offset: usize = 0;
                        while (extra_offset + 4 <= local_header.extra_len) {
                            const header_id = std.mem.readInt(
                                u16,
                                extra[extra_offset..][0..2],
                                .little,
                            );
                            const data_size = std.mem.readInt(
                                u16,
                                extra[extra_offset..][2..4],
                                .little,
                            );
                            const end = extra_offset + 4 + data_size;
                            if (end > local_header.extra_len)
                                return error.ZipBadExtraFieldSize;
                            const data = extra[extra_offset + 4 .. end];
                            switch (@as(std.zip.ExtraHeader, @enumFromInt(header_id))) {
                                .zip64_info => try readZip64FileExtents(
                                    std.zip.LocalFileHeader,
                                    local_header,
                                    &extents,
                                    data,
                                ),
                                else => {}, // ignore
                            }
                            extra_offset = end;
                        }
                    }

                    if (extents.compressed_size != 0 and
                        extents.compressed_size != self.entry.compressed_size)
                        return error.ZipMismatchCompLen;
                    if (extents.uncompressed_size != 0 and
                        extents.uncompressed_size != self.entry.uncompressed_size)
                        return error.ZipMismatchUncompLen;

                    if (local_header.filename_len != self.entry.filename_len)
                        return error.ZipMismatchFilenameLen;

                    break :res @as(u64, local_header.filename_len) + @as(
                        u64,
                        local_header.extra_len,
                    );
                };
                const local_data_file_offset: u64 = @as(u64, self.entry.file_offset) + @as(
                    u64,
                    @sizeOf(std.zip.LocalFileHeader),
                ) + local_data_header_offset;
                try stream.seekTo(local_data_file_offset);

                var limited_reader = std.io.limitedReader(
                    stream.context.reader(),
                    self.entry.compressed_size,
                );

                const crc32 = try std.zip.decompress(
                    self.entry.compression_method,
                    self.entry.uncompressed_size,
                    limited_reader.reader(),
                    writer,
                );
                std.debug.assert(crc32 == self.entry.crc32);
            }
        };

        zip_stream: SeekableStream,

        const Self = @This();

        pub fn init(seekable_zip_stream: SeekableStream) Self {
            return .{ .zip_stream = seekable_zip_stream };
        }

        pub fn entry(self: Self, allocator: std.mem.Allocator, name: []const u8) !?Entry {
            var zip_iter = try ZipIterator.init(self.zip_stream);
            while (try zip_iter.next()) |zip_entry| {
                if (zip_entry.filename_len != name.len) {
                    continue;
                }
                const candidate_entry = try Entry.from(allocator, self.zip_stream, zip_entry);
                if (std.mem.eql(u8, candidate_entry.name, name)) {
                    return candidate_entry;
                } else {
                    candidate_entry.deinit();
                }
            }
            return null;
        }

        pub const EntryIterator = struct {
            zip_iter: ZipIterator,

            pub fn next(self: *@This(), allocator: std.mem.Allocator) !?Entry {
                if (try self.zip_iter.next()) |zip_entry| {
                    return try Entry.from(allocator, self.zip_iter.stream, zip_entry);
                }
                return null;
            }

            pub fn count(self: @This()) u64 {
                return self.zip_iter.cd_record_count;
            }
        };

        pub fn entry_iter(self: Self) !EntryIterator {
            return .{ .zip_iter = try ZipIterator.init(self.zip_stream) };
        }
    };
}
