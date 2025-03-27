const std = @import("std");

fn sliceZ(values: [*:null]?[*:0]const u8) [][*:0]u8 {
    var len: usize = 0;
    while (values[len] != null) : (len += 1) {}
    return @as([*][*:0]u8, @ptrCast(values))[0..len];
}

pub const Environ = struct {
    argv: [*:null]?[*:0]const u8,
    envp: [*:null]?[*:0]const u8,

    pub fn exportValues(self: @This()) void {
        std.os.environ = sliceZ(self.envp);
        std.os.argv = sliceZ(self.argv);
    }
};
