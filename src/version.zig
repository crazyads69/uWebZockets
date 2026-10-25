//! Single Zig source of truth for the release version.
//!
//! The package manifest repeats the version because the package manager reads
//! it without executing Zig code. `scripts/bump_version.sh` rewrites the
//! manifest, the C ABI macros, the C/C++ tests, and the documentation headers;
//! `scripts/check_release_version.sh` fails the lint workflow when any copy
//! drifts from this module.

const std = @import("std");

/// Parsed release version; `build.zig` injects this into the build graph.
pub const semantic = std.SemanticVersion{ .major = 2, .minor = 1, .patch = 5 };

/// Dotted release string for the C ABI and OpenAPI defaults.
pub const string = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    semantic.major,
    semantic.minor,
    semantic.patch,
});
