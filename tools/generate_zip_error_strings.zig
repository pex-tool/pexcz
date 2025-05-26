const std = @import("std");

const usage =
    \\Usage: ./generate_zip_error_strings -SSCRIPT -IINCLUDE_DIR OUTPUT_FILE
    \\
;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    var opt_script_file_path: ?[]const u8 = null;
    var opt_include_dir_path: ?[]const u8 = null;
    var opt_output_file_path: ?[]const u8 = null;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                try std.io.getStdOut().writeAll(usage);
                return std.process.cleanExit();
            } else if (std.mem.startsWith(u8, arg, "-S")) {
                opt_script_file_path = arg[2..arg.len];
            } else if (std.mem.startsWith(u8, arg, "-I")) {
                opt_include_dir_path = arg[2..arg.len];
            } else {
                if (opt_output_file_path) |path| {
                    fatal("Only one output file is accepted, already specified {s}.", .{path});
                }
                opt_output_file_path = arg;
            }
        }
    }
    const script_file_path = opt_script_file_path orelse fatal(
        "A -S script file argument is required.",
        .{},
    );
    const include_dir_path = opt_include_dir_path orelse fatal(
        "A -I include directory argument is required.",
        .{},
    );
    const output_file_path = opt_output_file_path orelse fatal(
        "An output file argument is required.",
        .{},
    );
    try generate_zip_error_strings(arena, script_file_path, include_dir_path, output_file_path);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn generate_zip_error_strings(
    allocator: std.mem.Allocator,
    script_file_path: []const u8,
    include_path: []const u8,
    output_file_path: []const u8,
) !void {
    var process = std.process.Child.init(&.{
        "uv",
        "run",
        "--no-project",
        "--script",
        script_file_path,
        "-I",
        include_path,
        output_file_path,
    }, allocator);
    const term = try process.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.GenerateZipErrorStringsError;
        },
        else => return error.GenerateZipErrorStringsError,
    }
}
