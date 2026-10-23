const std = @import("std");
const sanitizers = @import("../sanitizers.zig");

/// Handles for the BoringSSL static libraries.
pub const Artifacts = struct {
    include_root: std.Build.LazyPath,
    crypto: *std.Build.Step.Compile,
    ssl: *std.Build.Step.Compile,
};

/// The pre-generated per-target source lists shipped with the pinned package.
///
/// Reading them keeps compile coverage identical to the upstream build graph
/// without maintaining a hand-copied list of hundreds of translation units.
const Sources = struct {
    crypto: Target,
    bcm: Target,
    ssl: Target,

    const Target = struct {
        srcs: []const []const u8,
        @"asm": []const []const u8 = &.{},
    };
};

const source_list_limit = 8 * 1024 * 1024;

/// Builds static `libcrypto.a` and `libssl.a` from the pinned BoringSSL package.
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
) Artifacts {
    const dependency = b.dependency("boringssl", .{});
    const root = dependency.path("");
    const include_root = root.path(b, "include");
    const lists = read_sources(b, dependency.path("gen/sources.json"));
    const is_windows = target.result.os.tag == .windows;
    // Upstream disables assembly on Windows and under MemorySanitizer, where
    // un-instrumented assembly would violate the sanitizer's shadow state.
    const disable_asm = is_windows or sanitizer.memory_sanitize;

    var definitions: std.ArrayList([]const u8) = .empty;
    definitions.append(b.allocator, "-DBORINGSSL_IMPLEMENTATION") catch @panic("out of memory");
    append_platform_definitions(b, &definitions, target, disable_asm);
    if (optimize != .Debug) {
        definitions.append(b.allocator, "-DNDEBUG") catch @panic("out of memory");
    }

    const cxx_flags = language_flags(b, "-std=gnu++17", definitions.items, sanitizer);
    const crypto_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    crypto_module.addIncludePath(include_root);
    crypto_module.addCSourceFiles(.{
        .root = root,
        .files = lists.crypto.srcs,
        .flags = cxx_flags,
    });
    crypto_module.addCSourceFiles(.{
        .root = root,
        .files = lists.bcm.srcs,
        .flags = cxx_flags,
    });
    if (!disable_asm) {
        // Every assembly source self-guards on architecture, OS, and
        // OPENSSL_NO_ASM, so the full list is safe to hand to the assembler.
        crypto_module.addCSourceFiles(.{
            .root = root,
            .files = lists.crypto.@"asm",
            .flags = definitions.items,
        });
        crypto_module.addCSourceFiles(.{
            .root = root,
            .files = lists.bcm.@"asm",
            .flags = definitions.items,
        });
    }
    const crypto = b.addLibrary(.{
        .linkage = .static,
        .name = "crypto",
        .root_module = crypto_module,
    });

    const ssl_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    ssl_module.addIncludePath(include_root);
    ssl_module.addCSourceFiles(.{
        .root = root,
        .files = lists.ssl.srcs,
        .flags = cxx_flags,
    });
    ssl_module.linkLibrary(crypto);
    const ssl = b.addLibrary(.{
        .linkage = .static,
        .name = "ssl",
        .root_module = ssl_module,
    });

    return .{
        .include_root = include_root,
        .crypto = crypto,
        .ssl = ssl,
    };
}

fn read_sources(b: *std.Build, sources_path: std.Build.LazyPath) Sources {
    const path = sources_path.getPath(b);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(source_list_limit),
    ) catch |err| {
        @panic(b.fmt("unable to read BoringSSL source list '{s}': {s}", .{
            path,
            @errorName(err),
        }));
    };
    const parsed = std.json.parseFromSlice(Sources, b.allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        @panic(b.fmt("unable to parse BoringSSL source list '{s}': {s}", .{
            path,
            @errorName(err),
        }));
    };
    return parsed.value;
}

fn append_platform_definitions(
    b: *std.Build,
    definitions: *std.ArrayList([]const u8),
    target: std.Build.ResolvedTarget,
    disable_asm: bool,
) void {
    const platform: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{
            "-D_CRT_SECURE_NO_WARNINGS",
            "-D_HAS_EXCEPTIONS=0",
            "-DNOMINMAX",
            "-DWIN32_LEAN_AND_MEAN",
        },
        .linux => &.{"-D_XOPEN_SOURCE=700"},
        else => &.{},
    };
    definitions.appendSlice(b.allocator, platform) catch @panic("out of memory");
    if (disable_asm) {
        definitions.append(b.allocator, "-DOPENSSL_NO_ASM") catch @panic("out of memory");
    }
}

fn language_flags(
    b: *std.Build,
    standard: []const u8,
    definitions: []const []const u8,
    sanitizer: sanitizers.Config,
) []const []const u8 {
    const base = sanitizers.instrumented_flags(b, &.{
        standard,
        "-fno-common",
        "-fno-strict-aliasing",
        "-fvisibility=hidden",
        "-fno-exceptions",
        "-fno-rtti",
        "-ffunction-sections",
        "-fdata-sections",
    }, sanitizer);
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, base) catch @panic("out of memory");
    flags.appendSlice(b.allocator, definitions) catch @panic("out of memory");
    return flags.items;
}
