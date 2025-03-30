const Elf32_Ehdr = std.elf.Elf32_Ehdr;
const Elf64_Ehdr = std.elf.Elf64_Ehdr;
const native_os = @import("builtin").target.os.tag;
const std = @import("std");

pub const Marker = @import("pep-508/Marker.zig");
pub const Tag = @import("pep-425.zig").Tag;
const TempDirs = @import("fs.zig").TempDirs;
const cache = @import("cache.zig");
const subprocess = @import("subprocess.zig");

const Version = struct {
    major: u8,
    minor: u8,

    const Self = @This();

    fn parse(version: []const u8) !Self {
        var version_component_iter = std.mem.splitScalar(u8, version, '.');
        const major = version_component_iter.next() orelse return error.VersionParseError;
        const minor = version_component_iter.next() orelse return error.VersionParseError;
        const major_rev = try std.fmt.parseUnsigned(u8, major, 10);
        const minor_rev = try std.fmt.parseUnsigned(u8, minor, 10);
        return .{ .major = major_rev, .minor = minor_rev };
    }
};

const Manylinux = struct {
    glibc: ?Version,
    armhf: bool,
    i686: bool,

    const Self = @This();

    fn fromHeader(parse_source: anytype, header: std.elf.Header, version: ?Version) !Self {
        const @"32bit little endian" = !header.is_64 and header.endian == .little;
        const armhf = res: {
            if (!@"32bit little endian" or header.machine != .ARM) {
                break :res false;
            }

            var hdr_buf: [@sizeOf(Elf64_Ehdr)]u8 align(@alignOf(Elf64_Ehdr)) = undefined;
            try parse_source.seekableStream().seekTo(0);
            try parse_source.reader().readNoEof(&hdr_buf);
            const hdr32 = @as(*const Elf32_Ehdr, @ptrCast(&hdr_buf));

            // The e_flags for 32 bit arm are documented here:
            //   https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst#52elf-header
            const EF_ARM_ABIMASK = 0xFF000000;
            const EF_ARM_ABI_VER5 = 0x05000000;
            const EF_ARM_ABI_FLOAT_HARD = 0x00000400;
            if (hdr32.e_flags & EF_ARM_ABIMASK != EF_ARM_ABI_VER5) {
                break :res false;
            }
            if (hdr32.e_flags & EF_ARM_ABI_FLOAT_HARD != EF_ARM_ABI_FLOAT_HARD) {
                break :res false;
            }

            break :res true;
        };

        const @"i686" = @"32bit little endian" and header.machine == .@"386";
        return .{ .glibc = version, .armhf = armhf, .i686 = @"i686" };
    }
};

const Linux = union(enum) {
    manylinux: Manylinux,
    muslinux: Version,

    const Self = @This();

    fn detect(allocator: std.mem.Allocator, python: []const u8) !?Self {
        if (native_os != .linux) {
            return null;
        }

        var python_exe = try std.fs.cwd().openFile(python, .{});
        defer python_exe.close();

        var gnu_libc_version: ?Version = null;

        const elf_header = try std.elf.Header.read(python_exe);
        var prog_header_iter = elf_header.program_header_iterator(python_exe);
        while (try prog_header_iter.next()) |header| {
            if (header.p_type != std.elf.PT_INTERP) {
                continue;
            }

            try python_exe.seekTo(header.p_offset);
            const interpreter = try python_exe.reader().readUntilDelimiterAlloc(
                allocator,
                0,
                @intCast(header.p_filesz),
            );

            // N.B.: Support for Version field in musl >= 0.9.15 only (01/03/2014)
            //   but musllinux support only added in
            //   https://peps.python.org/pep-0656/ in 2021:
            // :; docker run --rm -it python:alpine /lib/ld-musl-x86_64.so.1 >/dev/null
            // musl libc (x86_64)
            // Version 1.2.5
            // Dynamic Program Loader
            // Usage: /lib/ld-musl-x86_64.so.1 [options] [--] pathname [args]
            if (std.mem.containsAtLeast(u8, interpreter, 1, "musl")) {
                const Parser = struct {
                    pub fn parse(result: subprocess.RunResult) !Version {
                        var lines = std.mem.splitScalar(u8, result.stderr, '\n');
                        const prefix = "Version ";
                        while (lines.next()) |line| {
                            if (std.mem.startsWith(u8, line, prefix)) {
                                return try Version.parse(
                                    std.mem.trimRight(u8, line[prefix.len..line.len], " \n"),
                                );
                            }
                        } else {
                            return error.InterpreterIdentificationError;
                        }
                    }
                    pub fn printError(
                        args: struct { python_exe_path: []const u8, interpreter_path: []const u8 },
                    ) void {
                        std.debug.print(
                            "Failed to identify musl libc version of python interpreter at {s} " ++
                                "using {s}.",
                            .{ args.python_exe_path, args.interpreter_path },
                        );
                    }
                };
                return .{
                    .muslinux = try subprocess.run(
                        Version,
                        Parser,
                        .{
                            .allocator = allocator,
                            .argv = &.{interpreter},
                            .print_error_args = .{ .python_exe_path = python, .interpreter_path = interpreter },
                        },
                    ),
                };
            }

            // N.B.: Support for --version in glibc >= 2.33 only (01/02/2021)
            //   used by >= ubuntu:21.04. The maylinux spec started with
            //   https://peps.python.org/pep-0513/ in 2016; so this does not cover
            //   it.
            // :; /lib64/ld-linux-x86-64.so.2 --version 2>/dev/null
            // ld.so (Ubuntu GLIBC 2.41-6ubuntu1) stable release version 2.41.
            // Copyright (C) 2025 Free Software Foundation, Inc.
            // This is free software; see the source for copying conditions.
            // There is NO warranty; not even for MERCHANTABILITY or FITNESS FOR A
            // PARTICULAR PURPOSE.
            const Parser = struct {
                pub fn parse(res: subprocess.RunResult) ?Version {
                    if (std.meta.eql(res.term, .{ .Exited = 0 })) {
                        var lines = std.mem.splitScalar(u8, res.stdout, '\n');
                        if (lines.next()) |line| {
                            const prefix = "release version ";
                            if (std.mem.lastIndexOf(u8, line, prefix)) |index| {
                                if (std.mem.endsWith(u8, line, ".")) {
                                    const version = line[index + prefix.len .. line.len - 1];
                                    return Version.parse(version) catch null;
                                }
                            }
                        }
                    }
                    return null;
                }
                pub fn printError(
                    args: struct { python_exe_path: []const u8, interpreter_path: []const u8 },
                ) void {
                    std.debug.print(
                        "Failed to identify gnu libc version of python interpreter at {s} " ++
                            "using {s}.\n",
                        .{ args.python_exe_path, args.interpreter_path },
                    );
                }
            };
            gnu_libc_version = subprocess.run(
                ?Version,
                Parser,
                .{
                    .allocator = allocator,
                    .argv = &.{ interpreter, "--version" },
                    .print_error_args = .{ .python_exe_path = python, .interpreter_path = interpreter },
                },
            ) catch null;
        }
        return .{ .manylinux = try Manylinux.fromHeader(
            &python_exe,
            elf_header,
            gnu_libc_version,
        ) };
    }
};

const interpreter_py = @embedFile("interpreter.py");

pub const VersionInfo = struct {
    major: u8,
    minor: u8,
    micro: u8,
    releaselevel: []const u8,
    serial: u8,
};

pub const Interpreter = struct {
    path: []const u8,
    prefix: []const u8,
    base_prefix: ?[]const u8,
    version: VersionInfo,
    marker_env: Marker.Env,
    macos_framework_build: bool,
    supported_tags: []const Tag,
    // TODO: XXX: add supported tags.

    const Self = @This();

    pub fn identify(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Self) {
        var temp_dirs = TempDirs.init(allocator);
        defer temp_dirs.deinit();

        const pexcz_root = try cache.root(allocator, &temp_dirs, .{});
        defer pexcz_root.deinit(.{});

        // TODO(John Sirois): Re-consider key hashing scheme - compare to Pex.
        const Hasher = std.crypto.hash.sha2.Sha256;
        var digest: [Hasher.digest_length]u8 = undefined;
        Hasher.hash(path, &digest, .{});

        const encoder = std.fs.base64_encoder;
        // N.B.: This is the correct value for a 32 byte hash (sha256).
        var key_buf: [43]u8 = undefined;
        const key = encoder.encode(&key_buf, &digest);
        const expected_size = encoder.calcSize(Hasher.digest_length);
        std.debug.assert(expected_size == key.len);

        var interpeter_cache = try pexcz_root.join(&.{ "interpreters", "0", key });
        defer interpeter_cache.deinit(.{});

        const Work = struct {
            allocator: std.mem.Allocator,
            python: []const u8,

            fn work(work_path: []const u8, work_dir: std.fs.Dir, context: @This()) !void {
                var timer = try std.time.Timer.start();
                defer std.debug.print(
                    "interpreter identification took {d:.3}µs\n",
                    .{timer.read() / 1_000},
                );

                const linux_info = res: {
                    defer std.debug.print(
                        "Linux libc detection took {d:.3}µs\n",
                        .{timer.lap() / 1_000},
                    );
                    const linux = try Linux.detect(context.allocator, context.python);
                    break :res linux;
                };
                if (linux_info) |linux| {
                    std.debug.print("Detected Linux for {s}: {}\n", .{ context.python, linux });
                }

                const Parser = struct {
                    pub fn parse(id_result: subprocess.RunResult) !void {
                        switch (id_result.term) {
                            .Exited => |code| {
                                if (code != 0) return error.InterpreterIdentificationError;
                            },
                            else => return error.InterpreterIdentificationError,
                        }
                    }
                    pub fn printError(python: []const u8) void {
                        std.debug.print("Failed to identify interpreter at {s}.\n", .{python});
                    }
                };
                try subprocess.run(
                    void,
                    Parser,
                    .{
                        .allocator = context.allocator,
                        .argv = &.{ context.python, "-sE", "-c", interpreter_py, "info.json" },
                        .print_error_args = context.python,
                        .extra_child_run_args = .{
                            .cwd = work_path,
                            .cwd_dir = work_dir,
                        },
                    },
                );
            }
        };
        const work: Work = .{ .allocator = allocator, .python = path };
        var interpeter_cache_dir = try interpeter_cache.createAtomic(Work, Work.work, work, .{});
        defer interpeter_cache_dir.close();

        var buf: [100 * 1024]u8 = undefined;
        const data = try interpeter_cache_dir.readFile("info.json", &buf);
        std.debug.assert(data.len < buf.len);

        return try std.json.parseFromSlice(
            Interpreter,
            allocator,
            data,
            .{ .allocate = .alloc_always },
        );
    }
};

pub const InterpreterIter = struct {
    pub fn next(_: @This()) ?Interpreter {
        return null;
    }
};
