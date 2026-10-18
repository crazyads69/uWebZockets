const std = @import("std");
const sanitizers = @import("sanitizers.zig");
const vendor = @import("vendor/root.zig");

/// Handles for the `test` and `test-compile` steps.
pub const Steps = struct {
    test_step: *std.Build.Step,
    test_compile: *std.Build.Step,
};

pub fn inject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    archive_check: *std.Build.Step.Run,
    dependencies: vendor.Artifacts,
    sanitizer: sanitizers.Config,
    zslay: *std.Build.Module,
    xev: *std.Build.Module,
) Steps {
    add_compliance_server(
        b,
        "h1spec",
        "tests/h1spec/main.zig",
        "Run the h1spec compliance server",
        target,
        optimize,
        module,
        sanitizer,
    );
    add_compliance_server(
        b,
        "autobahn",
        "tests/autobahn/main.zig",
        "Run the Autobahn compliance server",
        target,
        optimize,
        module,
        sanitizer,
    );

    const http2_module = b.createModule(.{
        .root_source_file = b.path("src/http2/connection.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http2_hpack_module = b.createModule(.{
        .root_source_file = b.path("src/http2/hpack.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_support = b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("c", dependencies.c_module);
    test_support.addImport("xev", xev);
    test_support.addImport("zslay", zslay);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    // Sanitizer runs set `use_sigaltstack=0` in the run environment: ASan
    // installs an alternate signal stack per thread and unmaps whichever stack
    // it finds on thread teardown, while Zig's TLS-backed stack is not page
    // aligned. Leak detection and halt-on-error stay enabled.
    const test_options = b.addOptions();
    test_options.addOption(bool, "sanitize", sanitizer.sanitize);
    test_options.addOption(bool, "memory_sanitize", sanitizer.memory_sanitize);
    test_module.addOptions("test_options", test_options);
    test_module.addImport("c", dependencies.c_module);
    test_module.addImport("xev", xev);
    test_module.addImport("zslay", zslay);
    test_module.addImport("http2", http2_module);
    test_module.addImport("http2_hpack", http2_hpack_module);
    test_module.addImport("test_support", test_support);
    test_module.linkLibrary(library);
    dependencies.link(test_module);
    sanitizer.attach(test_module);

    const centralized_tests = b.addTest(.{ .root_module = test_module });
    const run_tests = sanitizers.add_run_artifact(b, centralized_tests, sanitizer.run);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&archive_check.step);
    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&centralized_tests.step);
    test_compile_step.dependOn(&archive_check.step);

    add_c_api_smoke(
        b,
        target,
        optimize,
        library,
        dependencies,
        sanitizer,
        test_step,
        test_compile_step,
    );
    add_cpp_header_check(b, target, optimize, test_step, test_compile_step);
    add_msan_smoke(b, target, optimize, library, dependencies, sanitizer);
    return .{ .test_step = test_step, .test_compile = test_compile_step };
}

fn add_compliance_server(
    b: *std.Build,
    step_name: []const u8,
    source: []const u8,
    description: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    sanitizer: sanitizers.Config,
) void {
    const artifact_name = if (std.mem.eql(u8, step_name, "autobahn")) "autobahn_server" else step_name;
    const executable = b.addExecutable(.{
        .name = artifact_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("uWebZockets", module);
    b.installArtifact(executable);
    const run = sanitizers.add_run_artifact(b, executable, sanitizer.run);
    b.step(step_name, description).dependOn(&run.step);
}

fn add_c_api_smoke(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Step.Compile,
    dependencies: vendor.Artifacts,
    sanitizer: sanitizers.Config,
    test_step: *std.Build.Step,
    test_compile_step: *std.Build.Step,
) void {
    const c_api_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    c_api_module.addIncludePath(b.path("include"));
    c_api_module.addCSourceFile(.{
        .file = b.path("tests/c_api/smoke.c"),
        .flags = if (sanitizer.sanitize)
            &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-pedantic",
                "-fsanitize=address",
                "-fsanitize=undefined",
                "-fno-sanitize-recover=undefined",
                "-fno-omit-frame-pointer",
            }
        else
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    c_api_module.linkLibrary(library);
    dependencies.link(c_api_module);
    if (sanitizer.sanitize) sanitizer.attach(c_api_module);

    const executable = b.addExecutable(.{ .name = "c_api_smoke", .root_module = c_api_module });
    const run = sanitizers.add_run_artifact(b, executable, sanitizer.run);
    test_step.dependOn(&run.step);
    test_compile_step.dependOn(&executable.step);
}

fn add_cpp_header_check(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    test_compile_step: *std.Build.Step,
) void {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{
        .file = b.path("tests/c_api/header_cpp.cc"),
        .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    const object = b.addObject(.{ .name = "c_api_header_cpp", .root_module = module });
    test_step.dependOn(&object.step);
    test_compile_step.dependOn(&object.step);
}

fn add_msan_smoke(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Step.Compile,
    dependencies: vendor.Artifacts,
    sanitizer: sanitizers.Config,
) void {
    const msan_step = b.step("msan", "Run the fully instrumented C/C++ dependency boundary smoke test");
    if (!sanitizer.memory_sanitize) {
        msan_step.dependOn(&b.addFail("msan requires -Dmemory-sanitize=true").step);
        return;
    }

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
        .omit_frame_pointer = false,
    });
    dependencies.add_includes(module);
    module.addCSourceFile(.{
        .file = b.path("tests/sanitizers/msan_smoke.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fsanitize=memory",
            "-fsanitize-memory-track-origins",
            "-fno-omit-frame-pointer",
            "-fPIE",
        },
    });
    dependencies.link(module);
    sanitizer.attach(module);
    const executable = b.addExecutable(.{ .name = "msan_smoke", .root_module = module });
    executable.pie = true;
    executable.step.dependOn(&library.step);
    const run = sanitizers.add_run_artifact(b, executable, .{
        .enabled = false,
        .dynamic_linker = null,
        .library_path = "",
        .shared_object = "",
    });
    msan_step.dependOn(&run.step);
}
