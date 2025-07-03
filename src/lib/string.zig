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
