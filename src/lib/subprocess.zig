const std = @import("std");

const Child = @import("vendor").zig.std.process.Child;
pub const RunResult = Child.RunResult;

const ChildRunArgs = @typeInfo(@TypeOf(Child.run)).@"fn".params[0].type.?;

const ExtraChildRunArgs = res: {
    const args_struct_info = @typeInfo(ChildRunArgs).@"struct";
    var fields: [args_struct_info.fields.len - 2]std.builtin.Type.StructField = undefined;
    var index: usize = 0;
    for (args_struct_info.fields) |field| {
        if (std.mem.eql(u8, field.name, "allocator")) {
            continue;
        }
        if (std.mem.eql(u8, field.name, "argv")) {
            continue;
        }
        if (field.default_value_ptr == null) {
            @compileLog(
                "Expected all Child.run args not including allocator and argv to have " ++
                    "defaults, but found no default for",
                field.name,
            );
        }
        fields[index] = field;
        index += 1;
    }
    const ExtraChildRunArgsStruct: std.builtin.Type.Struct = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    };
    break :res @Type(.{ .@"struct" = ExtraChildRunArgsStruct });
};

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    Parser: anytype,
    args: struct {
        print_error_args: @typeInfo(@TypeOf(@field(Parser, "printError"))).@"fn".params[0].type.?,
        extra_child_run_args: ExtraChildRunArgs = .{},
    },
    Result: anytype,
) !Result {
    var child_run_args: ChildRunArgs = .{ .allocator = allocator, .argv = argv };
    inline for (@typeInfo(ExtraChildRunArgs).@"struct".fields) |field| {
        @field(child_run_args, field.name) = @field(args.extra_child_run_args, field.name);
    }
    const result = try Child.run(child_run_args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    errdefer {
        Parser.printError(args.print_error_args);
        std.debug.print(
            \\
            \\STDOUT:
            \\{s}
            \\
            \\STDERR:
            \\{s}
            \\
        ,
            .{ result.stdout, result.stderr },
        );
    }
    return Parser.parse(result);
}
