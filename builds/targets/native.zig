const std = @import("std");
const examples = @import("../examples.zig");
const fuzzing = @import("../fuzzing.zig");
const sanitizers = @import("../sanitizers.zig");
const testing = @import("../testing.zig");
const vendor = @import("../vendor/root.zig");

/// Step handles produced by the native testing graph.
pub const Steps = testing.Steps;

pub fn inject(
    b: *std.Build,
    version: std.SemanticVersion,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    target_is_native: bool,
) Steps {
    const sanitizer = sanitizers.configure(b, target, target_is_native);
    const zslay_dependency = b.dependency("zslay", .{ .target = target, .optimize = optimize });
    const xev_dependency = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const zslay = zslay_dependency.module("zslay");
    // The IOCP accept fix is carried as an auditable overlay because the
    // pinned libxev revision predates it. Copy the dependency once and replace
    // the single patched file so Zig's package cache is never modified.
    const xev_tree = b.addWriteFiles();
    _ = xev_tree.addCopyDirectory(xev_dependency.path(""), "", .{});
    _ = xev_tree.addCopyFile(
        b.path("vendor/libxev_overlay/src/backend/iocp.zig"),
        "src/backend/iocp.zig",
    );
    const xev_impl = b.createModule(.{
        .root_source_file = xev_tree.getDirectory().path(b, "src/main.zig"),
    });
    // Transport code imports this shim as "xev" so the loop can fall back from
    // io_uring to epoll at runtime; the patched libxev is imported underneath.
    const xev = b.createModule(.{
        .root_source_file = b.path("src/core/xev.zig"),
        .target = target,
        .optimize = optimize,
    });
    xev.addImport("xev_impl", xev_impl);

    const module = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    module.link_libc = true;
    module.link_libcpp = true;
    module.addImport("zslay", zslay);
    module.addImport("xev", xev);

    const archive_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
        .link_libc = true,
        .link_libcpp = true,
    });
    archive_module.addImport("zslay", zslay);
    archive_module.addImport("xev", xev);

    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = archive_module,
        .version = version,
    });
    const dependencies = vendor.configure(b, target, optimize, sanitizer);
    dependencies.add_includes(module);
    dependencies.add_includes(archive_module);
    module.addImport("c", dependencies.c_module);
    archive_module.addImport("c", dependencies.c_module);
    archive_module.addCSourceFile(.{
        .file = b.path("src/quic/lsquic_shim.c"),
        .flags = sanitizer.c_flags(),
    });
    vendor.add_platform_libraries(archive_module, target);
    module.linkLibrary(library);
    dependencies.link(module);
    sanitizer.attach(module);

    const archive_check = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/check_static_archive.sh") });
    archive_check.addFileArg(library.getEmittedBin());
    const install_library = b.addInstallArtifact(library, .{});
    install_library.step.dependOn(&archive_check.step);
    b.getInstallStep().dependOn(&install_library.step);
    const library_step = b.step("lib", "Build and install only the static library");
    library_step.dependOn(&install_library.step);

    const install_header = b.addInstallHeaderFile(b.path("include/uWebZockets.h"), "uWebZockets.h");
    b.getInstallStep().dependOn(&install_header.step);
    library_step.dependOn(&install_header.step);
    install_vendor_libraries(b, dependencies, library_step);

    examples.inject(b, target, optimize, module, sanitizer);
    const test_steps = testing.inject(
        b,
        target,
        optimize,
        module,
        library,
        archive_check,
        dependencies,
        sanitizer,
        zslay,
        xev,
    );
    fuzzing.inject(b, target, optimize, dependencies, sanitizer, zslay, xev);
    return .{ .test_step = test_steps.test_step, .test_compile = test_steps.test_compile };
}

fn install_vendor_libraries(
    b: *std.Build,
    dependencies: vendor.Artifacts,
    library_step: *std.Build.Step,
) void {
    const libraries = [_]*std.Build.Step.Compile{
        dependencies.bssl.ssl,
        dependencies.bssl.crypto,
        dependencies.lsquic.library,
        dependencies.deflate.library,
        dependencies.z.library,
    };
    for (libraries) |artifact| {
        const install = b.addInstallArtifact(artifact, .{});
        b.getInstallStep().dependOn(&install.step);
        library_step.dependOn(&install.step);
    }
}
