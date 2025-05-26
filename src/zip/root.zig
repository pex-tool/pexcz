const std = @import("std");
const c = @cImport({
    @cInclude("zip.h");
});

const log = std.log.scoped(.zip);

inline fn logEnabled(level: std.log.Level) bool {
    return std.log.logEnabled(level, .zip);
}

pub const Zip = struct {
    pub const OpenOptions = struct {
        pub const Mode = enum(c_int) {
            read_only = c.ZIP_RDONLY,
            write = c.ZIP_CREATE,
            truncate = c.ZIP_CREATE | c.ZIP_TRUNCATE,
        };

        mode: Mode = .read_only,
    };

    handle: *c.zip_t,

    pub fn init(filename: [*c]const u8, options: Zip.OpenOptions) !Zip {
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
        return Zip{
            .handle = handle,
        };
    }

    pub fn clone(self: Zip, allocator: std.mem.Allocator) !Zip {
        var zip_clone = try allocator.create(Zip);
        zip_clone.handle = try allocator.create(c.zip_t);
        @memcpy(zip_clone.handle, self.handle);
        return zip_clone.*;
    }

    pub fn deinit(self: Zip) void {
        const zip_errno = c.zip_close(self.handle);
        if (zip_errno != 0 and logEnabled(.warn)) {
            var zip_error: c.zip_error_t = undefined;
            c.zip_error_init_with_code(&zip_error, zip_errno);
            defer c.zip_error_fini(&zip_error);
            log.warn("Failed to close zip file: {s}", .{c.zip_error_strerror(&zip_error)});
        }
    }
};
