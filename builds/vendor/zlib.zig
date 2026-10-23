const std = @import("std");
const sanitizers = @import("../sanitizers.zig");

/// zlib 1.3.2 sources for the DEFLATE windows that libdeflate cannot encode.
///
/// The pinned release tarball ships the generated `zconf.h` and `crc32.h`, so
/// no configure or generation step runs during the build.
const sources = [_][]const u8{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "infback.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};

/// Handles for the zlib static library and its public headers.
pub const Artifacts = struct {
    include_root: std.Build.LazyPath,
    library: *std.Build.Step.Compile,
};

/// Builds a static `libz.a` from the pinned zlib package.
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
) Artifacts {
    const dependency = b.dependency("zlib", .{});
    const root = dependency.path("");
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(root);
    module.addCSourceFiles(.{
        .root = root,
        .files = &sources,
        .flags = sanitizers.instrumented_flags(b, &.{ "-std=gnu11", "-ffunction-sections", "-fdata-sections" }, sanitizer),
    });
    return .{
        .include_root = root,
        .library = b.addLibrary(.{
            .linkage = .static,
            .name = "z",
            .root_module = module,
        }),
    };
}
