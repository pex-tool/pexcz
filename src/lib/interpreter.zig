const Elf32_Ehdr = std.elf.Elf32_Ehdr;
const Elf64_Ehdr = std.elf.Elf64_Ehdr;
const native_os = @import("builtin").target.os.tag;
const std = @import("std");

const TempDirs = @import("fs.zig").TempDirs;
const cache = @import("cache.zig");
const getenv = @import("os.zig").getenv;
const subprocess = @import("subprocess.zig");
pub const Marker = @import("Marker.zig");
pub const RankedTags = @import("RankedTags.zig");
pub const Tag = @import("Tag.zig");

const log = std.log.scoped(.interpreter);

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
            defer allocator.free(interpreter);

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
                        allocator,
                        &.{interpreter},
                        Parser,
                        .{
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
                allocator,
                &.{ interpreter, "--version" },
                Parser,
                .{
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
    realpath: []const u8,
    prefix: []const u8,
    base_prefix: ?[]const u8,
    version: VersionInfo,
    marker_env: Marker.Env,
    macos_framework_build: bool,

    // TODO: XXX: See if we can just keep tags as []const u8 opaque strings for set membership
    //  tests.
    supported_tags: []const Tag,

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
                defer log.debug(
                    "interpreter identification took {d:.3}µs",
                    .{timer.read() / 1_000},
                );

                const linux_info = res: {
                    defer log.debug("Linux libc detection took {d:.3}µs", .{timer.lap() / 1_000});
                    const linux = try Linux.detect(context.allocator, context.python);
                    break :res linux;
                };

                var argc: usize = 5;
                var argv = [_][]const u8{
                    context.python,
                    "-sE",
                    "-c",
                    interpreter_py,
                    "info.json",
                    "--linux-info",
                    "<replace me>",
                };
                if (linux_info) |linux| {
                    argv[argv.len - 1] = try std.json.stringifyAlloc(
                        context.allocator,
                        linux,
                        .{},
                    );
                    argc = argv.len;
                    log.debug(
                        "Detected Linux for {s}:\n{s}",
                        .{ context.python, argv[argv.len - 1] },
                    );
                }
                defer if (argc == argv.len) context.allocator.free(argv[argv.len - 1]);

                const CheckCall = struct {
                    pub fn printError(python: []const u8) void {
                        std.debug.print("Failed to identify interpreter at {s}.\n", .{python});
                    }
                };
                try subprocess.run(
                    context.allocator,
                    argv[0..argc],
                    subprocess.CheckCall(CheckCall.printError),
                    .{
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

        const stat = try interpeter_cache_dir.statFile("info.json");
        const data = try interpeter_cache_dir.readFileAlloc(
            allocator,
            "info.json",
            @intCast(stat.size),
        );
        defer allocator.free(data);

        return try std.json.parseFromSlice(
            Interpreter,
            allocator,
            data,
            .{ .allocate = .alloc_always },
        );
    }

    pub fn rankedTags(self: Self, allocator: std.mem.Allocator) !RankedTags {
        return RankedTags.init(allocator, self.supported_tags);
    }
};

pub const InterpreterIter = struct {
    allocator: std.mem.Allocator,
    index: usize = 0,
    candidates: []const []const u8,

    const Self = @This();

    fn fromSearchPath(allocator: std.mem.Allocator, search_path: ?[]const []const u8) !Self {
        var path = search_path;
        if (path == null) {
            if (try getenv(allocator, "PATH")) |path_entries| {
                defer path_entries.deinit();
                if (native_os == .windows) std.log.warn("Read PATH: {s}", .{path_entries.value});

                var buf = std.ArrayList([]const u8).init(allocator);
                errdefer {
                    for (buf.items) |entry| {
                        allocator.free(entry);
                    }
                    buf.deinit();
                }

                var path_iter = std.mem.splitScalar(u8, path_entries.value, std.fs.path.delimiter);
                while (path_iter.next()) |entry| {
                    try buf.append(try allocator.dupe(u8, entry));
                }
                path = try buf.toOwnedSlice();
            }
        }
        defer {
            if (search_path == null and path != null) {
                for (path.?) |entry| {
                    allocator.free(entry);
                }
                allocator.free(path.?);
            }
        }

        if (path == null) {
            return error.NoSearchPath;
        }

        var candidates = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (candidates.items) |candidate| {
                allocator.free(candidate);
            }
            candidates.deinit();
        }

        for (path.?) |entry| {
            if (native_os == .windows) {
                log.warn("About to try to open dir: {s} {x} ...", .{ entry, entry });
            }
            var entry_dir = std.fs.cwd().openDir(entry, .{ .iterate = true }) catch |err| {
                log.debug("Cannot open PATH entry {s}, continuing: {}", .{ entry, err });
                continue;
            };
            defer entry_dir.close();

            if (native_os == .windows) {
                // TODO: XXX: What is pypy called on Windows? - double check.
                for ([_][]const u8{
                    "python.exe",
                    "pythonw.exe",
                    "pypy.exe",
                    "pypyw.exe",
                }) |exe_name| {
                    if (entry_dir.access(exe_name, .{})) |_| {
                        const candidate = try std.fs.path.join(allocator, &.{ entry, exe_name });
                        errdefer allocator.free(candidate);
                        try candidates.append(candidate);
                    } else |_| {}
                }
            } else {
                // TODO: XXX: Macos capital-P Python?
                var dir_iter = entry_dir.iterate();
                next_dir_ent: while (try dir_iter.next()) |dir_ent| {
                    switch (dir_ent.kind) {
                        .file, .sym_link => {
                            for ([_][]const u8{ "python", "pypy" }) |exe_prefix| {
                                if (!std.mem.startsWith(u8, dir_ent.name, exe_prefix)) {
                                    continue;
                                }
                                for ([_][]const u8{ "-config", ".py" }) |suffix| {
                                    if (std.mem.endsWith(u8, dir_ent.name, suffix)) {
                                        continue :next_dir_ent;
                                    }
                                }
                                var look_at = exe_prefix.len;
                                if (dir_ent.name.len > look_at) {
                                    if (std.fmt.charToDigit(
                                        dir_ent.name[look_at],
                                        10,
                                    )) |_| {} else |_| {
                                        continue;
                                    }
                                    look_at += 1;
                                    if (dir_ent.name.len > look_at) {
                                        if (dir_ent.name[look_at] != '.') {
                                            continue;
                                        }
                                        look_at += 1;
                                        if (dir_ent.name.len > look_at) {
                                            if (std.fmt.charToDigit(
                                                dir_ent.name[look_at],
                                                10,
                                            )) |_| {} else |_| {
                                                continue;
                                            }
                                        }
                                    }
                                }
                                if (entry_dir.access(dir_ent.name, .{})) |_| {
                                    if (entry_dir.statFile(dir_ent.name)) |stat| {
                                        if (stat.mode & std.posix.S.IXUSR == 0) {
                                            continue;
                                        }
                                    } else |_| {
                                        continue;
                                    }
                                    const candidate_file = entry_dir.openFile(
                                        dir_ent.name,
                                        .{},
                                    ) catch {
                                        continue;
                                    };
                                    defer candidate_file.close();
                                    var buf: [2]u8 = undefined;
                                    _ = candidate_file.reader().readAtLeast(&buf, 2) catch {
                                        continue;
                                    };
                                    if (std.mem.eql(u8, buf[0..2], "#!")) {
                                        continue;
                                    }

                                    const candidate = try std.fs.path.join(
                                        allocator,
                                        &.{ entry, dir_ent.name },
                                    );
                                    errdefer allocator.free(candidate);
                                    log.debug("... candidate: {s}", .{candidate});
                                    try candidates.append(candidate);
                                } else |_| {}
                            }
                        },
                        else => continue,
                    }
                }
            }
        }
        log.debug("Found {d} candidates.", .{candidates.items.len});
        return .{ .allocator = allocator, .candidates = try candidates.toOwnedSlice() };
    }

    pub fn next(self: *Self) ?std.json.Parsed(Interpreter) {
        if (self.index >= self.candidates.len) {
            return null;
        }
        defer self.index += 1;
        const candidate = self.candidates[self.index];
        return Interpreter.identify(self.allocator, candidate) catch |err| {
            log.debug("Candidate {s} failed identification: {}", .{ candidate, err });
            // TODO: XXX: Avoid recursion here - flatten with a loop.
            self.index += 1;
            return self.next();
        };
    }

    pub fn deinit(self: Self) void {
        for (self.candidates) |candidate| {
            self.allocator.free(candidate);
        }
        self.allocator.free(self.candidates);
    }
};

test "compare with packaging" {
    const Virtualenv = @import("Virtualenv.zig");

    var interpreters = try InterpreterIter.fromSearchPath(std.testing.allocator, null);
    defer interpreters.deinit();

    var seen = std.BufSet.init(std.testing.allocator);
    defer seen.deinit();

    while (interpreters.next()) |interpreter| {
        defer interpreter.deinit();

        if (seen.contains(interpreter.value.realpath)) {
            log.debug(
                "Skipping {s}, same as already tested {s}.",
                .{ interpreter.value.path, interpreter.value.realpath },
            );
            continue;
        }
        try seen.insert(interpreter.value.realpath);

        const version = interpreter.value.version;
        const actual_tags, const free_tags = res: {
            if (version.major == 2 or (version.major == 3 and version.minor <= 6)) {
                // The older versions of packaging that support these older Pythons miss one tag.
                // Newer packaging corrects this as does our implementation; so we omit the tag from
                // the packaging cross-check.
                const python = try std.fmt.allocPrint(
                    std.testing.allocator,
                    "cp{d}{d}",
                    .{ version.major, version.minor },
                );
                defer std.testing.allocator.free(python);

                var tags = try std.testing.allocator.alloc(
                    Tag,
                    interpreter.value.supported_tags.len - 1,
                );
                var index: usize = 0;
                for (interpreter.value.supported_tags) |tag| {
                    if (!std.mem.eql(u8, python, tag.python) or
                        !std.mem.eql(u8, "none", tag.abi) or
                        !std.mem.eql(u8, "any", tag.platform))
                    {
                        tags[index] = tag;
                        index += 1;
                    }
                }
                break :res .{ tags, true };
            } else {
                break :res .{ interpreter.value.supported_tags, false };
            }
        };
        defer if (free_tags) std.testing.allocator.free(actual_tags);

        var tmpdir = std.testing.tmpDir(.{});
        // N.B.: We cleanup this tmpdir only upon success at the end of the block to leave the
        // chroot around for inspection to debug failures.

        const venv = try Virtualenv.create(
            std.testing.allocator,
            interpreter.value,
            tmpdir.dir,
            .{ .include_pip = true },
        );
        defer venv.deinit();

        const CheckInstall = struct {
            pub fn printError() void {
                std.debug.print("Failed to install packaging.\n", .{});
            }
        };
        try subprocess.run(
            std.testing.allocator,
            &.{ venv.interpreter_relpath, "-m", "pip", "install", "packaging" },
            subprocess.CheckCall(CheckInstall.printError),
            .{ .extra_child_run_args = .{ .cwd_dir = venv.dir } },
        );

        const CheckQuery = struct {
            pub fn printError() void {
                std.debug.print("Failed to query packaging for sys tags.\n", .{});
            }
        };

        const output = try subprocess.run(
            std.testing.allocator,
            &.{
                venv.interpreter_relpath,
                "-c",
                \\import json
                \\import sys
                \\
                \\from packaging import tags
                \\
                \\
                \\json.dump(list(map(str, tags.sys_tags())), sys.stdout)
                \\
            },
            subprocess.CheckOutput(CheckQuery.printError),
            .{ .extra_child_run_args = .{ .cwd_dir = venv.dir, .max_output_bytes = 1024 * 1024 } },
        );
        defer std.testing.allocator.free(output);

        const parsed_tags = try std.json.parseFromSlice(
            []const Tag,
            std.testing.allocator,
            output,
            .{},
        );
        defer parsed_tags.deinit();

        try std.testing.expectEqualDeep(parsed_tags.value, actual_tags);
        tmpdir.cleanup();
    }

    // We should have found at least one Python interpreter to test against.
    try std.testing.expect(seen.count() > 0);
}
