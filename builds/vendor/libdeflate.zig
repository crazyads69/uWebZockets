const std = @import("std");
const sanitizers = @import("../sanitizers.zig");

/// libdeflate 1.26 sources. Architecture selection happens inside each
/// translation unit, so one list covers x86, ARM, and RISC-V targets.
///
/// Every SIMD variant is compiled with function target attributes and chosen
/// at runtime, which is why upstream needs no per-file `-m` flags.
const sources = [_][]const u8{
    "lib/utils.c",
    "lib/arm/cpu_features.c",
    "lib/x86/cpu_features.c",
    "lib/deflate_compress.c",
    "lib/deflate_decompress.c",
    "lib/adler32.c",
    "lib/zlib_compress.c",
    "lib/zlib_decompress.c",
    "lib/crc32.c",
    "lib/gzip_compress.c",
    "lib/gzip_decompress.c",
};

/// Handles for the libdeflate static library and its public headers.
pub const Artifacts = struct {
    include_root: std.Build.LazyPath,
    library: *std.Build.Step.Compile,
};

/// Builds a static `libdeflate.a` from the pinned libdeflate package.
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
) Artifacts {
    const dependency = b.dependency("libdeflate", .{});
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
        .flags = sanitizers.instrumented_flags(b, &.{
            "-std=gnu11",
            "-ffunction-sections",
            "-fdata-sections",
            // Clang derives the AVX-512 and VPCLMULQDQ intrinsics from the
            // evex512 target feature, which these function target attributes
            // do not request. Disable those paths and let runtime dispatch
            // fall back to the AVX2 and SSSE3 implementations.
            "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ",
            "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI",
        }, sanitizer),
    });
    return .{
        .include_root = root,
        .library = b.addLibrary(.{
            .linkage = .static,
            .name = "deflate",
            .root_module = module,
        }),
    };
}
