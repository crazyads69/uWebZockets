//! Ergonomic, compile-time server construction.
//!
//! `Server.builder(io)` starts a fluent chain whose `with_*` methods each
//! return a builder for a new `ServerConfig`. `build(allocator)` then performs
//! exactly one allocation: the contiguous slab that backs every pool, request,
//! message, queue, router, and optional compression region. Nothing on the
//! runtime I/O path allocates.

const std = @import("std");
const app_module = @import("app.zig");
const cluster_module = @import("cluster.zig");
const config_module = @import("config.zig");

/// Human-readable capacities accepted by the builder.
pub const ServerConfig = config_module.ServerConfig;
/// Named capacity presets such as `Preset.microservice`.
pub const Preset = config_module.ServerConfig.Preset;
/// Transport backend selector accepted by `with_kernel_bypass`.
pub const TransportMode = config_module.TransportMode;
/// Views over the single contiguous startup slab.
pub const SlabLayout = config_module.SlabLayout;
/// Defaults used when no `with_*` override is applied.
pub const default_config = config_module.default_config;

/// Fluent entry point for configured servers.
///
/// ```zig
/// var server = try Server.builder(init.io)
///     .preset(Preset.microservice)
///     .with_max_body_size(256 * 1024)
///     .build(std.heap.page_allocator);
/// defer server.deinit();
/// ```
pub const Server = struct {
    /// Starts a builder from the default configuration.
    pub fn builder(io: std.Io) configured_builder(default_config) {
        return .{ .io = io };
    }

    /// Starts a builder directly from a named preset.
    pub fn preset(io: std.Io, comptime config: ServerConfig) configured_builder(config) {
        return .{ .io = io };
    }
};

/// Compile-time specialized builder; every `with_*` returns a new builder type.
///
/// Capacities stay compile-time because they size the generated application
/// type. Passing a literal or a `const` value keeps the fluent syntax working;
/// a runtime-variable capacity is rejected at compile time by design.
pub fn configured_builder(comptime config: ServerConfig) type {
    comptime {
        config.validate() catch |err| @compileError(
            "invalid ServerConfig: " ++ @errorName(err),
        );
    }

    return struct {
        const Self = @This();

        /// Application type generated for this configuration.
        pub const AppType = app_module.configured_app_with_route_params(
            config.max_connections,
            config.max_ws_message_size,
            config.write_queue_size,
            config.idle_timeout_ms,
            config.max_route_params,
            config.h3_capacities(),
        );

        io: std.Io,

        /// Overrides the maximum simultaneous connection count.
        pub fn with_max_clients(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_connections = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum complete WebSocket message size.
        pub fn with_max_ws_message_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_ws_message_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the bounded pending-output bytes per connection.
        pub fn with_write_queue_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .write_queue_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/1.1 request body.
        pub fn with_max_body_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_body_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/1.1 request line.
        pub fn with_max_request_line_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_request_line_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/1.1 header block.
        pub fn with_max_header_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_header_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum number of headers accepted on one request.
        pub fn with_max_header_count(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_header_count = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum number of retained radix routing nodes.
        pub fn with_max_route_nodes(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_route_nodes = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum number of parameterized route patterns.
        pub fn with_max_pattern_routes(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_pattern_routes = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum number of ordered middleware callbacks.
        pub fn with_max_middleware(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_middleware = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum accepted route path length.
        pub fn with_max_route_path_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_route_path_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum route captures accepted on one request.
        pub fn with_max_route_params(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_route_params = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the bytes reserved for route paths kept for introspection.
        pub fn with_max_route_registry_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_route_registry_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/2 header block.
        pub fn with_max_h2_header_block_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h2_header_block_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/2 request body.
        pub fn with_max_h2_body_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h2_body_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest encoded HTTP/2 response header block.
        pub fn with_max_h2_response_header_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h2_response_header_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum HTTP/2 response header fields.
        pub fn with_max_h2_response_header_count(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h2_response_header_count = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/3 request body.
        pub fn with_max_h3_body_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h3_body_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest encoded HTTP/3 response header storage.
        pub fn with_max_h3_response_header_size(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h3_response_header_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum decoded HTTP/3 response header fields.
        pub fn with_max_h3_response_header_count(
            self: Self,
            comptime value: usize,
        ) configured_builder(config.with(.{ .max_h3_response_header_count = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the inactivity timeout; zero disables the sweeper.
        pub fn with_idle_timeout_ms(
            self: Self,
            comptime value: u64,
        ) configured_builder(config.with(.{ .idle_timeout_ms = value })) {
            return .{ .io = self.io };
        }

        /// Reserves RFC 7692 scratch in the startup slab when enabled.
        pub fn with_compression(
            self: Self,
            comptime enabled: bool,
        ) configured_builder(config.with(.{ .compression = enabled })) {
            return .{ .io = self.io };
        }

        /// Opens one per-worker gzip pool for `Response.end_gzip`.
        pub fn with_http_compression(
            self: Self,
            comptime enabled: bool,
        ) configured_builder(config.with(.{ .http_compression = enabled })) {
            return .{ .io = self.io };
        }

        /// Requests the opportunistic AF_XDP kernel-bypass transport.
        ///
        /// Non-Linux targets compile the request out, and Linux hosts that
        /// refuse the probe keep the standard stack and report the reason.
        pub fn with_kernel_bypass(
            self: Self,
            comptime enabled: bool,
        ) configured_builder(config.with(.{
            .transport = if (enabled) .kernel_bypass else .standard,
        })) {
            return .{ .io = self.io };
        }

        /// Reserves one SoA datagram ring per connection in the startup slab.
        ///
        /// `max_datagram_size` bounds each payload and `datagram_slots` bounds
        /// the queued depth; both must be nonzero to enable datagrams.
        pub fn with_webtransport_datagrams(
            self: Self,
            comptime max_datagram_size: usize,
            comptime datagram_slots: usize,
        ) configured_builder(config.with(.{
            .max_datagram_size = max_datagram_size,
            .datagram_slots = datagram_slots,
        })) {
            return .{ .io = self.io };
        }

        /// Overrides the AF_XDP UMEM geometry.
        pub fn with_xdp_umem(
            self: Self,
            comptime frame_size: usize,
            comptime frame_count: usize,
        ) configured_builder(config.with(.{
            .xdp_frame_size = frame_size,
            .xdp_frame_count = frame_count,
        })) {
            return .{ .io = self.io };
        }

        /// Serves the hidden Prometheus endpoint when enabled.
        pub fn with_observability(
            self: Self,
            comptime enabled: bool,
        ) configured_builder(config.with(.{ .observability = enabled })) {
            return .{ .io = self.io };
        }

        /// Overrides the hidden observability endpoint path.
        pub fn with_metrics_path(
            self: Self,
            comptime path: []const u8,
        ) configured_builder(config.with(.{ .metrics_path = path })) {
            return .{ .io = self.io };
        }

        /// Writes the startup wordmark, ready summary, and event lines when
        /// enabled.
        pub fn with_dev_log(
            self: Self,
            comptime enabled: bool,
        ) configured_builder(config.with(.{ .enable_dev_log = enabled })) {
            return .{ .io = self.io };
        }

        /// Watches `paths` recursively and reports file changes to the dev log.
        ///
        /// Requires `with_dev_log(true)`; paths are borrowed for the
        /// application lifetime. Linux reports changes in real time through
        /// inotify, other targets scan on the loop timer.
        pub fn with_watch_paths(
            self: Self,
            comptime paths: []const []const u8,
        ) configured_builder(config.with(.{ .watch_paths = paths })) {
            return .{ .io = self.io };
        }

        /// Replaces the whole configuration with a named preset or literal.
        pub fn preset(self: Self, comptime value: ServerConfig) configured_builder(value) {
            return .{ .io = self.io };
        }

        /// Returns the configuration this builder will build.
        pub fn configuration(self: Self) ServerConfig {
            _ = self;
            return config;
        }

        /// Returns the exact contiguous slab size `build` will allocate.
        pub fn slab_bytes(self: Self) config_module.Error!usize {
            _ = self;
            return config.slab_bytes();
        }

        /// Allocates the startup slab once and returns the ready application.
        ///
        /// Register routes on the returned value, then call `listen`/`run`.
        /// The value must stay at a stable address after listening.
        pub fn build(self: Self, allocator: std.mem.Allocator) !AppType {
            return AppType.init_configured(self.io, allocator, config);
        }

        /// Builds a shared-nothing worker group from this configuration.
        ///
        /// Every worker allocates its own slab, runs its own libxev loop, and
        /// binds the shared port through SO_REUSEPORT where the kernel supports
        /// it. Configure routes per worker with `Cluster.configure` before
        /// calling `listen` and `run`. Call `Cluster.enable_https` (or
        /// `enable_https_ephemeral`) after `configure` and before `listen` to
        /// give every worker its own TLS context.
        pub fn build_cluster(
            self: Self,
            allocator: std.mem.Allocator,
            comptime worker_count: usize,
            options: app_module.ClusterOptions,
        ) !AppType.cluster(worker_count) {
            return AppType.cluster(worker_count).init_with_options(
                allocator,
                self.io,
                config,
                options,
            );
        }

        /// Builds a fixed-capacity cluster with a runtime-selected worker count.
        ///
        /// `worker_capacity` sizes the compile-time worker, inbox, and thread
        /// arrays. `worker_count` must be nonzero and no larger than the
        /// capacity; this is the entry point for `UWEBZOCKETS_WORKERS` and
        /// CPU-count defaults without compiling a type per count.
        pub fn build_cluster_with_worker_count(
            self: Self,
            allocator: std.mem.Allocator,
            comptime worker_capacity: usize,
            worker_count: usize,
            options: app_module.ClusterOptions,
        ) !AppType.cluster(worker_capacity) {
            return AppType.cluster(worker_capacity).init_with_worker_count(
                allocator,
                self.io,
                config,
                options,
                worker_count,
            );
        }

        /// Resolves `UWEBZOCKETS_WORKERS`, or the platform CPU count, at startup.
        ///
        /// This is the environment-aware cluster entry point. Invalid, zero, or
        /// above-capacity values fail before any worker slab is allocated.
        pub fn build_cluster_from_environment(
            self: Self,
            allocator: std.mem.Allocator,
            comptime worker_capacity: usize,
            environ: *const std.process.Environ.Map,
            options: app_module.ClusterOptions,
        ) !AppType.cluster(worker_capacity) {
            const workers = try cluster_module.worker_count_from_environment(
                environ,
                worker_capacity,
            );
            return self.build_cluster_with_worker_count(
                allocator,
                worker_capacity,
                workers,
                options,
            );
        }
    };
}
