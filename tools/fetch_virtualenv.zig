const std = @import("std");

const VIRTUALENV_16_7_12_RELEASE_SHA = "fdfec65ff031997503fb409f365ee3aeb4c2c89f";

const usage =
    \\Usage: ./fetch_virtualenv [--sha SHA] OUTPUT_FILE
    \\
    \\Options:
    \\  --sha The sha to fetch virtualenv.py from https://github.com/pypa/virtualenv at.
    \\
;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    var opt_sha: ?[]const u8 = null;
    var opt_output_file_path: ?[]const u8 = null;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                try std.io.getStdOut().writeAll(usage);
                return std.process.cleanExit();
            } else if (std.mem.eql(u8, "--sha", arg)) {
                i += 1;
                if (i > args.len) fatal("Expected arg after '{s}'.", .{arg});
                if (opt_sha) |sha| {
                    fatal("Duplicated {s} argument. Already specified {s}", .{ arg, sha });
                }
                opt_sha = args[i];
            } else {
                if (opt_output_file_path) |path| {
                    fatal("Only one output file is accepted, already specified {s}.", .{path});
                }
                opt_output_file_path = arg;
            }
        }
    }
    const output_file_path = opt_output_file_path orelse fatal("An output file argument is required.", .{});
    try fetch_to(arena, output_file_path, opt_sha);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn fetch_to(allocator: std.mem.Allocator, output_path: []const u8, sha: ?[]const u8) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/pypa/virtualenv/{s}/virtualenv.py",
        .{sha orelse VIRTUALENV_16_7_12_RELEASE_SHA},
    );
    defer allocator.free(url);

    if (std.fs.path.dirname(output_path)) |parent_dir| {
        std.fs.cwd().makePath(parent_dir) catch |mkdir_err| {
            fatal(
                "Failed to create the {s} directory to fetch {s} to: {}\n",
                .{ parent_dir, url, mkdir_err },
            );
        };
    }

    var argc: usize = 5;
    var argv: [7][]const u8 = .{
        "curl",
        "-fL",
        url,
        "-o",
        output_path,
        "--oauth2-bearer",
        "<replace me>",
    };

    const bearer_token: ?[]u8 = std.process.getEnvVarOwned(
        allocator,
        "_PEXCZ_BUILD_FETCH_VIRTUALENV_BEARER",
    ) catch |err| res: {
        if (err == error.EnvironmentVariableNotFound) {
            break :res null;
        }
        return err;
    };
    defer if (argc == argv.len) allocator.free(argv[argv.len - 1]);

    if (bearer_token) |bearer| {
        argv[argv.len - 1] = bearer;
        argc = argv.len;
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..argc],
    }) catch |curl_launch_err| {
        fatal(
            "Failed to launch curl process to fetch {s} to {s}: {}",
            .{ url, output_path, curl_launch_err },
        );
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!std.meta.eql(result.term, std.process.Child.Term{ .Exited = 0 })) {
        return fatal("Failed to curl {s}:\n{s}", .{ url, result.stderr });
    }
}
