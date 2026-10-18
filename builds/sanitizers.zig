const std = @import("std");

/// C compiler flags applied to instrumented dependency sources.
pub const CFlags = []const []const u8;

/// Runtime loader wiring for one sanitizer-instrumented executable.
pub const SanitizerRunConfig = struct {
    enabled: bool,
    dynamic_linker: ?[]const u8,
    library_path: []const u8,
    shared_object: []const u8,
};

/// Resolved sanitizer options shared by the whole build graph.
pub const Config = struct {
    b: *std.Build,
    sanitize: bool,
    memory_sanitize: bool,
    instrument_c: bool,
    library_dir: ?[]const u8,
    libc_dir: ?[]const u8,
    dynamic_linker: ?[]const u8,
    runtime_name: []const u8,
    run: SanitizerRunConfig,

    pub fn attach(self: Config, module: *std.Build.Module) void {
        if (self.sanitize) {
            const runtime_path: std.Build.LazyPath = .{ .cwd_relative = self.library_dir.? };
            module.addLibraryPath(runtime_path);
            module.addRPath(runtime_path);
            if (self.libc_dir) |libc_dir| {
                const libc_path: std.Build.LazyPath = .{ .cwd_relative = libc_dir };
                module.addLibraryPath(libc_path);
                module.addRPath(libc_path);
            }
            module.linkSystemLibrary(self.runtime_name, .{
                .needed = true,
                .use_pkg_config = .no,
                .preferred_link_mode = .dynamic,
                .search_strategy = .no_fallback,
            });
            return;
        }
        if (!self.memory_sanitize) return;
        module.addLibraryPath(.{ .cwd_relative = self.library_dir.? });
        module.linkSystemLibrary("clang_rt.msan-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
        module.linkSystemLibrary("clang_rt.msan_cxx-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
    }

    pub fn c_flags(self: Config) CFlags {
        return instrumented_flags(self.b, &.{"-std=c11"}, self);
    }

    /// Instrumentation flags alone, for sources that set their own language standard.
    pub fn instrument_flags(self: Config) CFlags {
        if (self.sanitize) return &.{
            "-fsanitize=address",
            "-fsanitize=undefined",
            "-fno-sanitize-recover=undefined",
            "-fno-omit-frame-pointer",
        };
        if (self.memory_sanitize) return &.{
            "-fsanitize=memory",
            "-fsanitize-memory-track-origins",
            "-fno-omit-frame-pointer",
        };
        return &.{};
    }
};

/// Appends the active sanitizer instrumentation and the upstream-compatible
/// hardening profile to a base flag list.
///
/// Zig's release modes inject undefined-behavior traps, `_FORTIFY_SOURCE`, and
/// stack protectors into C and C++ sources. Upstream never builds these
/// libraries with that instrumentation, and lsquic's packet-header path trips
/// an injected `ud1` trap on CI. The fortified wrappers also hide zeroed
/// buffers from MemorySanitizer, so all three are disabled here and sanitizer
/// mode enables its own reporting checks after this point.
pub fn instrumented_flags(
    b: *std.Build,
    base: []const []const u8,
    sanitizer: Config,
) CFlags {
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, base) catch @panic("out of memory");
    flags.appendSlice(b.allocator, &.{
        "-D_FORTIFY_SOURCE=0",
        "-fno-sanitize=undefined",
        "-fno-stack-protector",
    }) catch @panic("out of memory");
    flags.appendSlice(b.allocator, sanitizer.instrument_flags()) catch @panic("out of memory");
    flags.append(b.allocator, "-fno-sanitize-trap=undefined") catch @panic("out of memory");
    return flags.items;
}

pub fn configure(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    target_is_native: bool,
) Config {
    const sanitize = b.option(
        bool,
        "sanitize",
        "Enable native Linux ASan and UBSan instrumentation",
    ) orelse false;
    const memory_sanitize = b.option(
        bool,
        "memory-sanitize",
        "Enable native x86_64 Linux MemorySanitizer instrumentation",
    ) orelse false;
    const instrument_c = sanitize or memory_sanitize;
    const library_dir = b.option(
        []const u8,
        "sanitizer-lib-dir",
        "Directory containing the LLVM sanitizer runtime libraries",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIB_DIR");
    const libc_dir = b.option(
        []const u8,
        "sanitizer-libc-dir",
        "Directory containing libc used by sanitizer runtimes",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIBC_DIR");
    const dynamic_linker = b.option(
        []const u8,
        "sanitizer-dynamic-linker",
        "Dynamic linker used by native sanitizer executables",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_DYNAMIC_LINKER");

    if (sanitize and memory_sanitize) {
        @panic("address/undefined and memory sanitizers are mutually exclusive");
    }
    if (instrument_c and (!target_is_native or target.result.os.tag != .linux)) {
        @panic("sanitizer instrumentation requires a native Linux target");
    }
    if (memory_sanitize and target.result.cpu.arch != .x86_64) {
        @panic("-Dmemory-sanitize=true supports native x86_64 Linux");
    }
    if (instrument_c and library_dir == null) {
        @panic("sanitizers require -Dsanitizer-lib-dir or UWEBZOCKETS_SANITIZER_LIB_DIR");
    }
    if (instrument_c and (libc_dir == null) != (dynamic_linker == null)) {
        @panic("sanitizer libc directory and dynamic linker must be configured together");
    }

    const runtime_name = if (sanitize)
        switch (target.result.cpu.arch) {
            .x86_64 => "clang_rt.asan-x86_64",
            .aarch64 => "clang_rt.asan-aarch64",
            else => @panic("-Dsanitize=true supports x86_64 and aarch64"),
        }
    else
        "";
    const shared_object = if (sanitize)
        b.pathJoin(&.{ library_dir.?, b.fmt("lib{s}.so", .{runtime_name}) })
    else
        "";
    const library_path = if (!sanitize)
        ""
    else if (libc_dir) |path|
        b.fmt("{s}:{s}", .{ library_dir.?, path })
    else
        library_dir.?;
    return .{
        .b = b,
        .sanitize = sanitize,
        .memory_sanitize = memory_sanitize,
        .instrument_c = instrument_c,
        .library_dir = library_dir,
        .libc_dir = libc_dir,
        .dynamic_linker = dynamic_linker,
        .runtime_name = runtime_name,
        .run = .{
            .enabled = sanitize,
            .dynamic_linker = dynamic_linker,
            .library_path = library_path,
            .shared_object = shared_object,
        },
    };
}

pub fn add_run_artifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    sanitizer: SanitizerRunConfig,
) *std.Build.Step.Run {
    if (!sanitizer.enabled) {
        const dynamic_linker = b.graph.environ_map.get(
            "UWEBZOCKETS_RUNTIME_DYNAMIC_LINKER",
        ) orelse return b.addRunArtifact(artifact);
        if (std.mem.indexOfScalar(u8, dynamic_linker, '*') != null or
            artifact.root_module.resolved_target.?.result.abi.isMusl() or
            artifact.root_module.resolved_target.?.result.os.tag == .windows)
        {
            return b.addRunArtifact(artifact);
        }
        const library_path = b.graph.environ_map.get(
            "UWEBZOCKETS_RUNTIME_LIBRARY_PATH",
        ) orelse @panic("Nix runtime loader requires its library path");

        if (artifact.kind == .@"test") {
            artifact.setExecCmd(&.{ dynamic_linker, "--library-path", library_path, null });
            return b.addRunArtifact(artifact);
        }
        const command = b.addSystemCommand(&.{ dynamic_linker, "--library-path", library_path });
        command.addArtifactArg(artifact);
        return command;
    }

    const dynamic_linker = sanitizer.dynamic_linker orelse {
        const command = b.addRunArtifact(artifact);
        command.setEnvironmentVariable("LD_PRELOAD", sanitizer.shared_object);
        disable_sanitizer_alt_stack(b, command);
        return command;
    };
    if (artifact.kind == .@"test") {
        artifact.setExecCmd(&.{
            dynamic_linker,
            "--library-path",
            sanitizer.library_path,
            "--preload",
            sanitizer.shared_object,
            null,
        });
        const command = b.addRunArtifact(artifact);
        disable_sanitizer_alt_stack(b, command);
        return command;
    }
    const command = b.addSystemCommand(&.{
        dynamic_linker,
        "--library-path",
        sanitizer.library_path,
        "--preload",
        sanitizer.shared_object,
    });
    command.addArtifactArg(artifact);
    disable_sanitizer_alt_stack(b, command);
    return command;
}

/// ASan installs an alternate signal stack for every thread and unmaps
/// whichever stack is installed when that thread exits. Zig 0.16's test runner
/// ignores a test root's `std_options.signal_stack_size`, so its thread-local
/// stack is installed, is not page aligned, and makes ASan abort the test
/// binary with a failed `munmap`. Disabling only the sanitizer's alternate
/// stack keeps leak detection, `halt_on_error`, and every check in place; the
/// affected path is the deep-stack-overflow handler. An existing
/// `use_sigaltstack` value in `ASAN_OPTIONS` is preserved.
fn disable_sanitizer_alt_stack(b: *std.Build, command: *std.Build.Step.Run) void {
    const existing = b.graph.environ_map.get("ASAN_OPTIONS");
    const value = if (existing) |options|
        if (std.mem.indexOf(u8, options, "use_sigaltstack=") != null)
            options
        else
            b.fmt("{s}:use_sigaltstack=0", .{options})
    else
        "use_sigaltstack=0";
    command.setEnvironmentVariable("ASAN_OPTIONS", value);
}
