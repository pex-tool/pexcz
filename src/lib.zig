const std = @import("std");

pub const Allocator = @import("lib/heap.zig").Allocator;
pub const Environ = @import("lib/process.zig").Environ;
pub const sliceZ = @import("lib/process.zig").sliceZ;
pub const ZipFile = @import("lib/zip.zig").Zip(std.fs.File.SeekableStream);
pub const bootPexZPosix = @import("lib/boot.zig").bootPexZPosix;
pub const bootPexZWindows = @import("lib/boot.zig").bootPexZWindows;
pub const cache = @import("lib/cache.zig");
pub const fs = @import("lib/fs.zig");
const interpreter = @import("lib/interpreter.zig");

test {
    _ = cache;
    _ = interpreter;
}
