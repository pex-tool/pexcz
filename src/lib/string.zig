const std = @import("std");

pub fn trim_ascii_ws(value: []const u8) []const u8 {
    if (value.len == 0) return "";

    var start_index: usize = 0;
    var end_index: usize = value.len - 1;
    while (start_index <= end_index and std.ascii.isWhitespace(value[start_index])) {
        start_index += 1;
    }
    while (end_index > start_index and std.ascii.isWhitespace(value[end_index])) end_index -= 1;

    return value[start_index .. end_index + 1];
}

test "empty" {
    try std.testing.expectEqualStrings("", trim_ascii_ws(""));
    try std.testing.expectEqualStrings("", trim_ascii_ws(" "));
    try std.testing.expectEqualStrings("", trim_ascii_ws(" \n"));
    try std.testing.expectEqualStrings("", trim_ascii_ws(" \r\n\t"));
}

test "non-empty" {
    try std.testing.expectEqualStrings("bob", trim_ascii_ws("bob"));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws(" bob"));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws("bob "));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws(" bob "));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws("\nbob "));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws("\nbob\t"));
    try std.testing.expectEqualStrings("bob", trim_ascii_ws("\n bob\t\r"));
}

pub const ShSafeString = struct {
    value: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: ShSafeString) void {
        if (self.allocator) |alloc| {
            alloc.free(self.value);
        }
    }
};

pub fn sh_quote(allocator: std.mem.Allocator, value: []const u8) !ShSafeString {
    if (value.len == 0) return .{ .value = "''" };
    var quoted: ?std.ArrayList(u8) = null;
    for (value, 0..) |char, index| {
        const needs_quote = switch (char) {
            // N.B.: Taken from Python shlex.quote which uses the regex `[^\w@%+=:,./-]` to
            // identify _unsafe_ characters that require escaping.
            'a'...'z', 'A'...'Z', '0'...'9', '_' => false, // This is Python's `\w` character class.
            '@', '%', '+', '=', ':', ',', '.', '/', '-' => false,
            else => true,
        };
        if (needs_quote and quoted == null) {
            quoted = try std.ArrayList(u8).initCapacity(allocator, value.len * 2);
            // Backfill.
            try quoted.?.append('\'');
            try quoted.?.appendSlice(value[0..index]);
        }
        if (quoted) |*sh_quoted| {
            if (char == '\'') {
                // N.B.: Once inside a single-quoted string, we need only quote the single quote
                // itself.
                try sh_quoted.appendSlice("'\"'\"'");
            } else {
                try sh_quoted.append(char);
            }
        }
    }
    if (quoted) |*sh_quoted| {
        try sh_quoted.append('\'');
        return .{ .value = try sh_quoted.toOwnedSlice(), .allocator = allocator };
    } else {
        return .{ .value = value };
    }
}

test "sh_quote empty" {
    const empty = try sh_quote(std.testing.allocator, "");
    try std.testing.expectEqual(null, empty.allocator);
    try std.testing.expectEqual("''", empty.value);
}

test "sh_quote noop" {
    const expectNotQuoted = struct {
        fn expectNotQuoted(value: []const u8) !void {
            const not_quoted = try sh_quote(std.testing.allocator, value);

            try std.testing.expectEqual(null, not_quoted.allocator);
            try std.testing.expectEqualStrings(value, not_quoted.value);
        }
    }.expectNotQuoted;

    try expectNotQuoted("BobTheBuilder");
    try expectNotQuoted("Bob/The/Builder");
}

test "sh_quote quoted" {
    const expectQuoted = struct {
        fn expectQuoted(expected: []const u8, value: []const u8) !void {
            const quoted = try sh_quote(std.testing.allocator, value);
            defer quoted.deinit();

            try std.testing.expectEqual(std.testing.allocator, quoted.allocator);
            try std.testing.expectEqualStrings(expected, quoted.value);
        }
    }.expectQuoted;

    try expectQuoted("' '", " ");
    try expectQuoted("'$PATH'", "$PATH");
    try expectQuoted("'!'", "!");
    try expectQuoted("'Bob The Builder'", "Bob The Builder");
}
