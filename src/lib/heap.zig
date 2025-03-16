const std = @import("std");
const builtin = @import("builtin");

fn Gpa(comptime config: std.heap.GeneralPurposeAllocatorConfig) type {
    return struct {
        const GPA = std.heap.GeneralPurposeAllocator(config);

        gpa: GPA,

        const Self = @This();

        pub fn init() Self {
            return .{ .gpa = GPA{} };
        }

        pub fn deinit(self: *Self) void {
            const check = self.gpa.deinit();
            std.debug.assert(check == .ok);
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.gpa.allocator();
        }
    };
}

const Arena = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init() Self {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub fn Allocator(comptime config: std.heap.GeneralPurposeAllocatorConfig) type {
    return switch (builtin.mode) {
        .Debug => Gpa(config),
        else => Arena,
    };
}
