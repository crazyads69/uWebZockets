const std = @import("std");
const boringssl = @import("boringssl.zig");
const sanitizers = @import("../sanitizers.zig");
const zlib = @import("zlib.zig");

/// Handles for the assembled lsquic source tree and its static library.
pub const Artifacts = struct {
    include_root: std.Build.LazyPath,
    wincompat_dir: std.Build.LazyPath,
    library: *std.Build.Step.Compile,
};

/// liblsquic translation units, relative to the assembled tree root.
///
/// This mirrors the pinned `src/liblsquic/CMakeLists.txt`. The maintained
/// fork commits the generated `lsquic_versions_to_string.c`, so the build
/// applies no source overlay.
///
/// ls-qpack and ls-hpack are pinned Zig package dependencies compiled as one
/// translation unit each. Neither repository has a generation step, system
/// tool requirement, or architecture-specific source; `XXH_HEADER_NAME` points
/// both at lsquic's bundled xxHash, and the only target-specific input is the
/// musl `sys/queue.h` compatibility header below.
const sources = [_][]const u8{
    "src/liblsquic/ls-qpack/lsqpack.c",
    "src/liblsquic/lsquic_adaptive_cc.c",
    "src/liblsquic/lsquic_alarmset.c",
    "src/liblsquic/lsquic_arr.c",
    "src/liblsquic/lsquic_attq.c",
    "src/liblsquic/lsquic_bbr.c",
    "src/liblsquic/lsquic_bw_sampler.c",
    "src/liblsquic/lsquic_cfcw.c",
    "src/liblsquic/lsquic_chsk_stream.c",
    "src/liblsquic/lsquic_conn.c",
    "src/liblsquic/lsquic_crand.c",
    "src/liblsquic/lsquic_crt_compress.c",
    "src/liblsquic/lsquic_crypto.c",
    "src/liblsquic/lsquic_cubic.c",
    "src/liblsquic/lsquic_di_error.c",
    "src/liblsquic/lsquic_di_hash.c",
    "src/liblsquic/lsquic_di_nocopy.c",
    "src/liblsquic/lsquic_enc_sess_common.c",
    "src/liblsquic/lsquic_enc_sess_ietf.c",
    "src/liblsquic/lsquic_eng_hist.c",
    "src/liblsquic/lsquic_engine.c",
    "src/liblsquic/lsquic_ev_log.c",
    "src/liblsquic/lsquic_frab_list.c",
    "src/liblsquic/lsquic_frame_common.c",
    "src/liblsquic/lsquic_frame_reader.c",
    "src/liblsquic/lsquic_frame_writer.c",
    "src/liblsquic/lsquic_full_conn.c",
    "src/liblsquic/lsquic_full_conn_ietf.c",
    "src/liblsquic/lsquic_global.c",
    "src/liblsquic/lsquic_handshake.c",
    "src/liblsquic/lsquic_hash.c",
    "src/liblsquic/lsquic_hcsi_reader.c",
    "src/liblsquic/lsquic_hcso_writer.c",
    "src/liblsquic/lsquic_headers_stream.c",
    "src/liblsquic/lsquic_hkdf.c",
    "src/liblsquic/lsquic_hpi.c",
    "src/liblsquic/lsquic_hspack_valid.c",
    "src/liblsquic/lsquic_http.c",
    "src/liblsquic/lsquic_http1x_if.c",
    "src/liblsquic/lsquic_logger.c",
    "src/liblsquic/lsquic_malo.c",
    "src/liblsquic/lsquic_min_heap.c",
    "src/liblsquic/lsquic_mini_conn.c",
    "src/liblsquic/lsquic_mini_conn_ietf.c",
    "src/liblsquic/lsquic_minmax.c",
    "src/liblsquic/lsquic_mm.c",
    "src/liblsquic/lsquic_pacer.c",
    "src/liblsquic/lsquic_packet_common.c",
    "src/liblsquic/lsquic_packet_gquic.c",
    "src/liblsquic/lsquic_packet_in.c",
    "src/liblsquic/lsquic_packet_out.c",
    "src/liblsquic/lsquic_packet_resize.c",
    "src/liblsquic/lsquic_parse_Q046.c",
    "src/liblsquic/lsquic_parse_Q050.c",
    "src/liblsquic/lsquic_parse_common.c",
    "src/liblsquic/lsquic_parse_gquic_be.c",
    "src/liblsquic/lsquic_parse_gquic_common.c",
    "src/liblsquic/lsquic_parse_ietf_v1.c",
    "src/liblsquic/lsquic_parse_iquic_common.c",
    "src/liblsquic/lsquic_pr_queue.c",
    "src/liblsquic/lsquic_purga.c",
    "src/liblsquic/lsquic_qdec_hdl.c",
    "src/liblsquic/lsquic_qenc_hdl.c",
    "src/liblsquic/lsquic_qlog.c",
    "src/liblsquic/lsquic_qpack_exp.c",
    "src/liblsquic/lsquic_rechist.c",
    "src/liblsquic/lsquic_rtt.c",
    "src/liblsquic/lsquic_send_ctl.c",
    "src/liblsquic/lsquic_senhist.c",
    "src/liblsquic/lsquic_set.c",
    "src/liblsquic/lsquic_sfcw.c",
    "src/liblsquic/lsquic_shsk_stream.c",
    "src/liblsquic/lsquic_spi.c",
    "src/liblsquic/lsquic_stock_shi.c",
    "src/liblsquic/lsquic_str.c",
    "src/liblsquic/lsquic_stream.c",
    "src/liblsquic/lsquic_tokgen.c",
    "src/liblsquic/lsquic_trans_params.c",
    "src/liblsquic/lsquic_trechist.c",
    "src/liblsquic/lsquic_util.c",
    "src/liblsquic/lsquic_varint.c",
    "src/liblsquic/lsquic_version.c",
    "src/liblsquic/lsquic_xxhash.c",
    "src/liblsquic/ls-sfparser.c",
    "src/liblsquic/lsquic_versions_to_string.c",
    "src/lshpack/lshpack.c",
};

/// Builds a static `liblsquic.a` from the pinned lsquic, ls-qpack, and
/// ls-hpack packages plus the pre-generated overlay.
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
    bssl: boringssl.Artifacts,
    z: zlib.Artifacts,
) Artifacts {
    const lsquic_dependency = b.dependency("lsquic", .{});
    const lsqpack_dependency = b.dependency("lsqpack", .{});
    const lshpack_dependency = b.dependency("lshpack", .{});

    const tree = b.addWriteFiles();
    _ = tree.addCopyDirectory(lsquic_dependency.path(""), "", .{});
    if (target.result.abi.isMusl()) {
        // musl does not ship the BSD queue macros that liblsquic includes.
        _ = tree.addCopyFile(
            lshpack_dependency.path("compat/queue/sys/queue.h"),
            "include/sys/queue.h",
        );
    }
    _ = tree.addCopyDirectory(
        lsqpack_dependency.path(""),
        "src/liblsquic/ls-qpack",
        .{},
    );
    _ = tree.addCopyDirectory(lshpack_dependency.path(""), "src/lshpack", .{});
    const tree_root = tree.getDirectory();

    const is_windows = target.result.os.tag == .windows;
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(tree_root.path(b, "src/liblsquic"));
    module.addIncludePath(tree_root.path(b, "include"));
    module.addIncludePath(tree_root.path(b, "src/liblsquic/ls-qpack"));
    module.addIncludePath(tree_root.path(b, "src/lshpack"));
    module.addIncludePath(bssl.include_root);
    module.addIncludePath(z.include_root);
    if (is_windows) {
        module.addIncludePath(tree_root.path(b, "wincompat"));
    }

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, sanitizers.instrumented_flags(
        b,
        &.{ "-std=gnu11", "-ffunction-sections", "-fdata-sections" },
        sanitizer,
    )) catch @panic("out of memory");
    for (definitions) |define| {
        flags.append(b.allocator, define) catch @panic("out of memory");
    }
    if (is_windows) {
        flags.appendSlice(b.allocator, &.{
            "-DNOMINMAX",
            "-DWIN32_LEAN_AND_MEAN",
        }) catch @panic("out of memory");
    }
    module.addCSourceFiles(.{
        .root = tree_root,
        .files = &sources,
        .flags = flags.items,
    });
    module.linkLibrary(bssl.crypto);
    module.linkLibrary(bssl.ssl);
    module.linkLibrary(z.library);

    return .{
        .include_root = tree_root.path(b, "include"),
        .wincompat_dir = tree_root.path(b, "wincompat"),
        .library = b.addLibrary(.{
            .linkage = .static,
            .name = "lsquic",
            .root_module = module,
        }),
    };
}

/// Macros that keep lsquic on its integrated ls-qpack, ls-hpack, and xxHash.
///
/// `XXH_HEADER_NAME` points both header-compression sources at the single
/// lsquic xxHash copy instead of their own bundled implementations.
const definitions = [_][]const u8{
    "-DHAVE_BORINGSSL",
    "-DLSQPACK_DEC_LOGGER_HEADER=\"lsquic_qpack_dec_logger.h\"",
    "-DLSQPACK_ENC_LOGGER_HEADER=\"lsquic_qpack_enc_logger.h\"",
    "-DLSQUIC_CONN_STATS=1",
    "-DLSQUIC_DEBUG_NEXT_ADV_TICK=1",
    "-DXXH_HEADER_NAME=\"lsquic_xxhash.h\"",
};
