const std = @import("std");

pub const Allocator = @import("lib/heap.zig").Allocator;
pub const ZipFile = @import("lib/zip.zig").Zip(std.fs.File.SeekableStream);
pub const bootPexZ = @import("lib/boot.zig").bootPexZ;
pub const fs = @import("lib/fs.zig");
pub const cache = @import("lib/cache.zig");

test {
    _ = cache;
}
