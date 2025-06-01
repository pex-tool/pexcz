const std = @import("std");
const builtin = @import("builtin");

const Debug = struct {
    const DebugAllocator = std.heap.DebugAllocator(
        .{ .safety = true, .verbose_log = true, .enable_memory_limit = true },
    );

    debug_allocator: DebugAllocator,

    const Self = @This();

    pub fn init() Self {
        return .{ .debug_allocator = DebugAllocator.init };
    }

    pub fn deinit(self: *Self) std.heap.Check {
        return self.debug_allocator.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.debug_allocator.allocator();
    }

    pub fn bytesUsed(self: Self) usize {
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

    pub fn deinit(self: *Self) std.heap.Check {
        self.arena.deinit();
        return .ok;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn bytesUsed(self: Self) usize {
        return self.arena.queryCapacity();
    }
};

pub const Allocator = switch (builtin.mode) {
    .Debug => Debug,
    else => Arena,
};
