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

fn structFnType(Type: anytype, name: []const u8) std.builtin.Type.Fn {
    return @typeInfo(@TypeOf(@field(Type, name))).@"fn";
}

fn FuncParamType(func: anytype, index: usize, Default: ?type) type {
    return FnParamType(@typeInfo(@TypeOf(func)).@"fn", index, Default);
}

fn FnParamType(func: std.builtin.Type.Fn, index: usize, Default: ?type) type {
    const params = func.params;
    if (params.len <= index) {
        if (Default) |ParamType| {
            return ParamType;
        }
        @compileError("Invalid function signature: too few arguments.");
    }
    if (params[index].type) |ParamType| {
        return ParamType;
    }
    if (Default) |ParamType| {
        return ParamType;
    }
    @compileError("Function parameter has no type.");
}

fn StructFnParamType(Type: anytype, name: []const u8, index: usize, default: ?type) type {
    return FnParamType(structFnType(Type, name), index, default);
}

fn StructFnResultType(Type: anytype, name: []const u8) type {
    const func = structFnType(Type, name);
    const ReturnType = func.return_type.?;
    return switch (@typeInfo(ReturnType)) {
        .error_union => |value| value.payload,
        else => ReturnType,
    };
}

fn parserOwnsStdout(Parser: anytype) ?bool {
    if (@hasDecl(Parser, "owns_stdout")) {
        const value = @field(Parser, "owns_stdout");
        if (@TypeOf(value) != bool) {
            @compileError("The subprocess.run Parser has an owns_stdout decl that is not a bool.");
        }
        return value;
    }
    return null;
}

fn parserOwnsStderr(Parser: anytype) ?bool {
    if (@hasDecl(Parser, "owns_stderr")) {
        const value = @field(Parser, "owns_stderr");
        if (@TypeOf(value) != bool) {
            @compileError("The subprocess.run Parser has an owns_stderr decl that is not a bool.");
        }
        return value;
    }
    return null;
}

fn callerOwnsStdout(Parser: anytype, args: Args(Parser)) bool {
    if (parserOwnsStdout(Parser)) |value| {
        return value;
    } else if (@hasField(@TypeOf(args), "caller_owns_stdout")) {
        return args.caller_owns_stdout;
    }
    return false;
}

fn callerOwnsStderr(Parser: anytype, args: Args(Parser)) bool {
    if (parserOwnsStderr(Parser)) |value| {
        return value;
    } else if (@hasField(@TypeOf(args), "caller_owns_stderr")) {
        return args.caller_owns_stderr;
    }
    return false;
}

fn Args(Parser: anytype) type {
    const ArgsType = struct {
        parse_args: StructFnParamType(Parser, "parse", 1, void),
        print_error_args: StructFnParamType(Parser, "printError", 0, void),
        caller_owns_stdout: bool = false,
        caller_owns_stderr: bool = false,
        extra_child_run_args: ExtraChildRunArgs = .{},
    };

    const omit_caller_owns_stdout = parserOwnsStdout(Parser) != null;
    const omit_caller_owns_stderr = parserOwnsStderr(Parser) != null;

    const args_struct_info = @typeInfo(ArgsType).@"struct";
    var fields: [args_struct_info.fields.len]std.builtin.Type.StructField = undefined;
    var index: usize = 0;
    for (args_struct_info.fields) |field| {
        if (field.type == void) {
            continue;
        }
        if (omit_caller_owns_stdout and std.mem.eql(u8, "caller_owns_stdout", field.name)) {
            continue;
        }
        if (omit_caller_owns_stderr and std.mem.eql(u8, "caller_owns_stderr", field.name)) {
            continue;
        }
        fields[index] = field;
        index += 1;
    }

    const ArgsTypeStruct: std.builtin.Type.Struct = .{
        .layout = .auto,
        .fields = fields[0..index],
        .decls = &.{},
        .is_tuple = false,
    };
    return @Type(.{ .@"struct" = ArgsTypeStruct });
}

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    Parser: anytype,
    args: Args(Parser),
) !StructFnResultType(Parser, "parse") {
    const caller_owns_stdout = callerOwnsStdout(Parser, args);
    const caller_owns_stderr = callerOwnsStderr(Parser, args);

    var child_run_args: ChildRunArgs = .{ .allocator = allocator, .argv = argv };
    inline for (@typeInfo(ExtraChildRunArgs).@"struct".fields) |field| {
        @field(child_run_args, field.name) = @field(args.extra_child_run_args, field.name);
    }
    const result = try Child.run(child_run_args);
    defer if (!caller_owns_stdout) allocator.free(result.stdout);
    defer if (!caller_owns_stderr) allocator.free(result.stderr);
    errdefer {
        const PrintErrorFnParamType = StructFnParamType(Parser, "printError", 0, void);
        if (PrintErrorFnParamType == void) {
            Parser.printError();
        } else {
            Parser.printError(args.print_error_args);
        }
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
        if (caller_owns_stdout) allocator.free(result.stdout);
        if (caller_owns_stderr) allocator.free(result.stdout);
    }
    const ParseFnParamType = StructFnParamType(Parser, "parse", 1, void);
    if (ParseFnParamType == void) {
        return Parser.parse(result);
    } else {
        return Parser.parse(result, args.parse_args);
    }
}

pub fn check_call(result: RunResult) !void {
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.InterpreterIdentificationError;
        },
        else => return error.InterpreterIdentificationError,
    }
}

pub fn CheckCall(printErrorFn: anytype) type {
    const ErrorFnParamType = FuncParamType(printErrorFn, 0, void);
    if (ErrorFnParamType == void) {
        return struct {
            pub fn parse(result: RunResult) !void {
                return check_call(result);
            }
            pub fn printError() void {
                printErrorFn();
            }
        };
    } else {
        return struct {
            pub fn parse(result: RunResult) !void {
                return check_call(result);
            }
            pub fn printError(args: ErrorFnParamType) void {
                printErrorFn(args);
            }
        };
    }
}

pub fn CheckOutput(printErrorFn: anytype) type {
    const ErrorFnParamType = FuncParamType(printErrorFn, 0, void);
    if (ErrorFnParamType == void) {
        return struct {
            pub const owns_stdout = true;
            pub const owns_stderr = false;
            pub fn parse(result: RunResult) ![]const u8 {
                try check_call(result);
                return result.stdout;
            }
            pub fn printError() void {
                printErrorFn();
            }
        };
    } else {
        return struct {
            pub const owns_stdout = true;
            pub const owns_stderr = false;
            pub fn parse(result: RunResult) ![]const u8 {
                try check_call(result);
                return result.stdout;
            }
            pub fn printError(args: ErrorFnParamType) void {
                printErrorFn(args);
            }
        };
    }
}
