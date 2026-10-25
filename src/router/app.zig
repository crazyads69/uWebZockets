const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_pool = @import("../core/pool.zig");
const core_timer = @import("../core/timer.zig");
const timer_wheel = @import("../core/timer_wheel.zig");
const core_affinity = @import("../core/affinity.zig");
const core_signal = @import("../core/signal.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const DeflateContext = @import("../ws/deflate.zig").Context;
const HttpCompressionPool = @import("../http/compression_pool.zig").Pool;
const ClientAuthConfig = @import("../crypto/tls.zig").ClientAuthConfig;
const TlsContext = @import("../crypto/tls.zig").TlsContext;
const quic = @import("../quic/engine.zig");
const quic_stream = @import("../quic/stream.zig");
const udp = @import("../core/udp.zig");
const request_module = @import("../http/request.zig");
const Request = request_module.Request;
const Response = @import("../http/response.zig").Response;
const json_rpc_http = @import("../rpc/http.zig");
const static_files_module = @import("../http/static_files.zig");
const cluster_module = @import("cluster.zig");
const worker_group_module = @import("worker_group.zig");
const config_module = @import("config.zig");
const datagram_module = @import("datagram.zig");
const datagram_ring_module = @import("../quic/datagram_ring.zig");
const metrics_module = @import("../observability/metrics.zig");
const dev_log_module = @import("../observability/dev_log.zig");
const terminal_module = @import("../observability/terminal.zig");
const file_watch_module = @import("../observability/file_watch.zig");
const ebpf_module = @import("../observability/ebpf.zig");
const xdp_transport_module = @import("../xdp/transport.zig");
const http_rejection = @import("../http/rejection.zig");

const log = std.log.scoped(.server);

/// Default maximum complete WebSocket message size per connection.
pub const default_max_ws_message_size = 16 * 1024;
/// Default bounded pending-output capacity per TCP connection.
pub const default_write_queue_size = core_tcp.default_write_queue_capacity;
/// Default inactivity timeout before an idle keep-alive connection is closed.
pub const default_idle_timeout_ms: u64 = 120_000;
/// Default time a connection may hold an incomplete request head or body.
pub const default_header_read_timeout_ms: u64 = 30_000;
/// Maximum simultaneously bound TCP listeners on one application.
pub const max_tcp_listeners = 4;

/// One TCP endpoint accepted by `App.listen_all`.
pub const TcpListenEndpoint = struct {
    address: []const u8,
    port: u16,
    /// Per-listener TLS selection; null follows the application's context.
    tls: ?bool = null,
};
/// Reports whether the compiled lsquic transport is available.
pub const http3_available = quic.available;

/// Startup policy for `App.cluster` worker groups.
pub const ClusterOptions = cluster_module.ClusterOptions;

/// Returns the default fixed-capacity application type.
pub fn app(comptime max_connections: usize) type {
    return configured_app(max_connections, default_max_ws_message_size, default_write_queue_size);
}

/// Returns an application type with explicit message and write capacities.
pub fn configured_app(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
) type {
    return configured_app_with_timeout(
        max_connections,
        max_ws_message_size,
        write_queue_size,
        default_idle_timeout_ms,
    );
}

/// Returns an application type with an explicit idle timeout policy.
pub fn configured_app_with_timeout(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
    comptime idle_timeout_ms: u64,
) type {
    return configured_app_with_route_params(
        max_connections,
        max_ws_message_size,
        write_queue_size,
        idle_timeout_ms,
        request_module.max_route_params,
        quic_stream.default_capacities,
    );
}

/// Returns an application type with explicit route capture and HTTP/3
/// capacities.
///
/// `max_route_params` counts the captures a request may hold; values above the
/// inline `Request.max_route_params` carve a per-connection extras region.
/// `h3_capacities` specializes the HTTP/3 stream type and the QUIC engine's
/// per-stream storage, so it must match `ServerConfig.h3_capacities()`.
pub fn configured_app_with_route_params(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
    comptime idle_timeout_ms: u64,
    comptime max_route_params: usize,
    comptime h3_capacities: quic_stream.Capacities,
) type {
    if (max_connections == 0) @compileError("connection capacity must be greater than zero");
    if (max_ws_message_size == 0) @compileError("WebSocket message capacity must be greater than zero");
    if (write_queue_size == 0) @compileError("write queue capacity must be greater than zero");
    if (max_route_params < request_module.max_route_params) {
        @compileError("route parameter capacity must cover the inline Request arrays");
    }
    if (max_connections > std.math.maxInt(usize) / max_ws_message_size) {
        @compileError("WebSocket message storage size overflows usize");
    }
    if (max_connections > std.math.maxInt(usize) / write_queue_size) {
        @compileError("write queue storage size overflows usize");
    }

    const route_param_extra_capacity = max_route_params - request_module.max_route_params;

    return struct {
        const Self = @This();
        /// Stable per-listener context passed to the accept callback.
        const ListenerBinding = struct {
            app: *Self,
            tls: bool,
        };
        const Pool = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections);
        const QuicEngine = quic.quic_engine(
            max_connections,
            write_queue_size,
            route_param_extra_capacity,
            h3_capacities,
        );
        const QuicTransport = udp.quic_transport(QuicEngine);
        const static_file_capacity = if (write_queue_size > 4096) write_queue_size - 4096 else write_queue_size;
        const StaticFiles = static_files_module.static_files(static_file_capacity);
        const ClusterInbox = cluster_module.message_queue(max_ws_message_size);
        const DatagramRing = datagram_ring_module.DatagramRing;
        const DatagramRouter = datagram_module.Router;
        const XdpTransport = xdp_transport_module.XdpTransport;
        const max_static_routes = 8;
        const default_config = config_module.ServerConfig{
            .max_connections = max_connections,
            .max_ws_message_size = max_ws_message_size,
            .write_queue_size = write_queue_size,
            .idle_timeout_ms = idle_timeout_ms,
            .header_read_timeout_ms = default_header_read_timeout_ms,
        };

        io: std.Io,
        loop: core_loop.Loop,
        pool: Pool,
        // One contiguous startup slab backs the pool, request, message, queue,
        // and router regions so deinit releases exactly one allocation.
        slab: []u8,
        slab_allocator: std.mem.Allocator,
        request_buffers: []u8,
        request_buffer_stride: usize,
        // Per-request parser limits and the shared extra-header pointer region.
        max_request_line_size: usize,
        max_header_size: usize,
        max_header_count: usize,
        header_extras: []align(config_module.request_buffer_alignment) u8,
        extra_header_capacity: usize,
        extra_header_stride: usize,
        // Per-connection route-capture pointer region beyond the inline
        // `Request` arrays; paired with the header-extras region.
        route_param_extras: []align(@alignOf([]const u8)) u8,
        extra_route_param_capacity: usize,
        extra_route_param_stride: usize,
        // Per-connection carved HTTP/2 session storage; the stride covers one
        // session's whole storage plan and stays aligned to it.
        h2_sessions: []u8,
        h2_session_stride: usize,
        h2_capacities: core_tcp.Http2Session.Capacities,
        max_body_size: usize,
        reject_policy: http_rejection.RejectionPolicy = .{},
        ws_message_storage: []u8,
        ws_compression_storage: []u8 = &.{},
        ws_compression_capacity: usize = 0,
        ws_compression_owned: bool = false,
        ws_deflate: ?DeflateContext = null,
        http_compression: ?HttpCompressionPool = null,
        write_queue_storage: []u8,
        // Router typed storage carved from the startup slab; the router binds
        // it on first route work, when the App address is stable.
        router_storage: radix.Storage = undefined,
        router_bound: bool = false,
        router: radix.Router = .{},
        // WebTransport datagram state. The metadata arrays are SoA and the
        // payload slab is one fixed stride per connection, all carved from the
        // startup slab so no datagram ever allocates.
        datagram_router: DatagramRouter = .{},
        datagram_session_ids: []u64 = &.{},
        datagram_sequences: []u64 = &.{},
        datagram_payload_lengths: []u32 = &.{},
        datagram_rings: []DatagramRing = &.{},
        datagram_payloads: []u8 = &.{},
        datagram_stride: usize = 0,
        // Kernel-bypass observability state.
        xdp_transport: ?*XdpTransport = null,
        transport_availability: xdp_transport_module.Availability = .{
            .mode = .standard,
            .reason = .none,
        },
        metrics_registry: ?*metrics_module.Registry = null,
        metrics_enabled: bool = false,
        metrics_installed: bool = false,
        metrics_path: []const u8 = "/metrics",
        dev_log_enabled: bool = false,
        dev_log_file: ?std.Io.File = null,
        watch_paths: []const []const u8 = &.{},
        ready_started_ns: u64 = 0,
        ebpf_map_fd: i32 = -1,
        static_handlers: [max_static_routes]?*StaticFiles = .{null} ** max_static_routes,
        static_handler_count: u8 = 0,
        cluster_inbox: ?*ClusterInbox = null,
        /// Cluster signal watcher anchored on this worker's loop, when this
        /// worker is worker 0 and the cluster installed one.
        cluster_signal_watcher: ?*core_signal.SignalWatcher = null,
        cluster_wakeup: ?xev.Async = null,
        cluster_completion: xev.Completion = .{},
        cluster_stop_requested: std.atomic.Value(bool) = .init(false),
        cluster_wakeup_active: bool = false,
        listeners: [max_tcp_listeners]core_tcp.TcpServer = undefined,
        bindings: [max_tcp_listeners]ListenerBinding = undefined,
        listener_count: usize = 0,
        scheduler: ?core_timer.Scheduler = null,
        heartbeat_timer: timer_wheel.TimerNode = .{},
        header_timeout_ms: u64 = default_header_read_timeout_ms,
        watcher: ?file_watch_module.Watcher = null,
        signal_watcher: ?core_signal.SignalWatcher = null,
        tls_ctx: ?TlsContext = null,
        quic_tls_ctx: ?TlsContext = null,
        quic_transport: ?QuicTransport = null,
        http3_enabled: bool = false,
        routes_locked: bool = false,
        shutting_down: bool = false,
        running: bool = false,
        deinitialized: bool = false,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        /// Initializes a plaintext application and its single fixed-capacity slab.
        pub fn init(io: std.Io) !Self {
            return init_configured(io, std.heap.page_allocator, default_config);
        }

        /// Allocates the whole startup slab once, then initializes from it.
        ///
        /// Every pool, request, message, queue, router, and optional compression
        /// region comes from this one allocation; the runtime I/O loop never
        /// allocates.
        pub fn init_configured(
            io: std.Io,
            allocator: std.mem.Allocator,
            comptime config: config_module.ServerConfig,
        ) !Self {
            const total = try config_module.required_bytes(config);
            const alignment = comptime std.mem.Alignment.fromByteUnits(
                config.required_alignment(),
            );
            const slab = try allocator.alignedAlloc(u8, alignment, total);
            errdefer allocator.free(slab);
            return init_from_slab(io, allocator, slab, config);
        }

        /// Initializes from caller-provided storage; ownership transfers on success.
        ///
        /// `slab` must be aligned to `config.required_alignment()` and hold at
        /// least `config_module.required_bytes(config)` bytes. The application
        /// releases the full slice through `allocator` in `deinit`; on failure
        /// the caller keeps ownership.
        pub fn init_from_slab(
            io: std.Io,
            allocator: std.mem.Allocator,
            slab: []u8,
            comptime config: config_module.ServerConfig,
        ) !Self {
            // The connection setup path slices regions with type-level
            // capacities, so a mismatched runtime config would index out of
            // bounds. Reject the mismatch where it originates.
            comptime {
                if (config.max_connections != max_connections) @compileError(
                    "ServerConfig.max_connections must match the generated App capacity",
                );
                if (config.max_ws_message_size != max_ws_message_size) @compileError(
                    "ServerConfig.max_ws_message_size must match the generated App capacity",
                );
                if (config.write_queue_size != write_queue_size) @compileError(
                    "ServerConfig.write_queue_size must match the generated App capacity",
                );
                if (config.idle_timeout_ms != idle_timeout_ms) @compileError(
                    "ServerConfig.idle_timeout_ms must match the generated App timeout",
                );
                if (config.max_route_params != max_route_params) @compileError(
                    "ServerConfig.max_route_params must match the generated App capacity",
                );
                // The QUIC engine type is specialized with these capacities, so
                // a mismatched runtime config would carve mismatched storage.
                if (!std.meta.eql(config.h3_capacities(), h3_capacities)) @compileError(
                    "ServerConfig HTTP/3 capacities must match the generated App capacity",
                );
            }

            const layout = try config_module.carve(slab, config);
            const extra_header_capacity = try config.extra_header_capacity();
            const extra_route_param_capacity = try config.extra_route_param_capacity();
            const router_storage = try radix.carve_storage(
                layout.router_storage,
                config.router_capacities(),
            );
            const compression_capacity = if (layout.compression_stride == 0)
                0
            else
                layout.compression_stride / 2;

            // One compressor pool is opened per worker during startup. A
            // request never allocates a codec, and a failure here releases the
            // context before the slab ownership is transferred.
            var ws_deflate: ?DeflateContext = null;
            errdefer if (ws_deflate) |*context| context.deinit();
            if (config.compression) {
                ws_deflate = try init_ws_deflate(compression_capacity, max_ws_message_size);
            }

            var http_compression: ?HttpCompressionPool = null;
            errdefer if (http_compression) |*pool| pool.deinit();
            if (config.http_compression) {
                http_compression = try HttpCompressionPool.init(config.max_body_size);
            }

            var loop = try core_loop.init();
            errdefer core_loop.deinit(&loop);

            const pool = try Pool.from_slices(layout.pool_storage, layout.freelist);

            var instance = Self{
                .io = io,
                .loop = loop,
                .pool = pool,
                .slab = slab,
                .slab_allocator = allocator,
                .request_buffers = layout.request_buffers,
                .request_buffer_stride = layout.request_buffer_stride,
                .max_request_line_size = config.max_request_line_size,
                .max_header_size = config.max_header_size,
                .max_header_count = config.max_header_count,
                .header_extras = @alignCast(layout.header_extras),
                .extra_header_capacity = extra_header_capacity,
                .extra_header_stride = layout.extra_header_stride,
                .route_param_extras = @alignCast(layout.route_param_extras),
                .extra_route_param_capacity = extra_route_param_capacity,
                .extra_route_param_stride = layout.extra_route_param_stride,
                .h2_sessions = layout.h2_sessions,
                .h2_session_stride = layout.h2_session_stride,
                .h2_capacities = config.h2_capacities(),
                .max_body_size = config.max_body_size,
                .header_timeout_ms = config.header_read_timeout_ms,
                .reject_policy = config.rejection_policy(),
                .ws_message_storage = layout.ws_messages,
                .ws_compression_storage = layout.compression_scratch,
                .ws_compression_capacity = compression_capacity,
                .ws_deflate = ws_deflate,
                .http_compression = http_compression,
                .write_queue_storage = layout.write_queues,
                .router_storage = router_storage,
                .datagram_session_ids = layout.datagram_session_ids,
                .datagram_sequences = layout.datagram_sequences,
                .datagram_payload_lengths = layout.datagram_payload_lengths,
                .datagram_rings = layout.datagram_rings,
                .datagram_payloads = layout.datagram_payloads,
                .datagram_stride = layout.datagram_stride,
                .metrics_registry = layout.metrics_registry,
                .metrics_enabled = config.observability,
                .metrics_path = if (config.observability) config.metrics_path else "/metrics",
                .dev_log_enabled = config.enable_dev_log,
                .watch_paths = config.watch_paths,
                .pubsub = .{},
            };

            if (instance.metrics_registry) |registry| registry.* = .{};
            // Monotonic start mark for the ready summary; the clock is
            // non-negative on every supported target.
            instance.ready_started_ns = @intCast(@max(std.Io.Clock.now(.awake, io).nanoseconds, 0));

            if (layout.datagram_rings.len != 0) {
                const slots = config.datagram_slots;
                const payload_stride = config.max_datagram_size;
                for (layout.datagram_rings, 0..) |*ring, index| {
                    const metadata_start = index * slots;
                    const payload_start = index * layout.datagram_stride;
                    // Validation bounded the slot count and stride, and the
                    // slab carved exactly `stride * connections` payload bytes.
                    ring.* = DatagramRing.init(
                        layout.datagram_session_ids[metadata_start .. metadata_start + slots],
                        layout.datagram_sequences[metadata_start .. metadata_start + slots],
                        layout.datagram_payload_lengths[metadata_start .. metadata_start + slots],
                        layout.datagram_payloads[payload_start .. payload_start + layout.datagram_stride],
                        payload_stride,
                    ) catch unreachable;
                }
            }

            // The bypass is requested at compile time but the server data path
            // never dispatches through it; reporting a live bypass would be a
            // false claim. The transport stays available to callers that drive
            // it themselves, so only the availability report and the fallback
            // counter change here.
            if (comptime config.transport == .kernel_bypass) {
                instance.transport_availability = .{
                    .mode = .standard,
                    .reason = .data_path_unwired,
                };
                if (instance.metrics_registry) |registry| {
                    registry.set(.xdp_kernel_bypass_fallbacks, 1);
                }
            }

            if (config.observability and ebpf_module.available()) {
                instance.ebpf_map_fd = ebpf_module.open_pinned(ebpf_map_path) catch -1;
            }
            return instance;
        }

        /// Initializes an HTTPS application from NUL-terminated certificate paths.
        ///
        /// Use `init_https_ephemeral` for local development when no
        /// certificate files exist.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            return instance;
        }

        /// Initializes an HTTPS application that authenticates clients with
        /// certificates issued by the CA bundle in `config.ca_path`.
        ///
        /// ALPN matches `init_https`, but every client-authentication mode
        /// disables TLS 1.3 0-RTT: the client certificate is not verified
        /// until the second flight, so early data cannot be admitted under
        /// mTLS. Client authentication is TCP-only in 1.7.0; the HTTP/3
        /// listener keeps its `init_http3` policy, so use `init_http3` when
        /// QUIC is also required.
        pub fn init_https_mtls(
            io: std.Io,
            cert_path: [:0]const u8,
            key_path: [:0]const u8,
            config: ClientAuthConfig,
        ) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init_mtls(cert_path, key_path, config);
            return instance;
        }

        /// Initializes isolated TCP/TLS and HTTP/3/QUIC server contexts.
        ///
        /// Use `init_http3_ephemeral` for local development when no
        /// certificate files exist.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            instance.quic_tls_ctx = try TlsContext.init_http3(cert_path, key_path);
            instance.http3_enabled = true;
            return instance;
        }

        /// Initializes an HTTPS application with an in-memory self-signed
        /// certificate for `localhost`, `127.0.0.1`, and `::1`.
        ///
        /// Use this for local development and tests when no certificate files
        /// exist; production deployments must pass real paths to `init_https`.
        pub fn init_https_ephemeral(io: std.Io) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init_ephemeral(.{});
            return instance;
        }

        /// Initializes a dual HTTPS and HTTP/3 application with in-memory
        /// self-signed certificates for `localhost`, `127.0.0.1`, and `::1`.
        pub fn init_http3_ephemeral(io: std.Io) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init_ephemeral(.{});
            instance.quic_tls_ctx = try TlsContext.init_http3_ephemeral(.{});
            instance.http3_enabled = true;
            return instance;
        }

        /// Releases this application's TLS context exactly once.
        fn release_tls(self: *Self) void {
            if (self.tls_ctx) |*tls| tls.deinit();
            self.tls_ctx = null;
        }

        /// Releases all application resources after shutdown has drained completions.
        pub fn deinit(self: *Self) void {
            if (self.deinitialized) return;
            if (self.running) {
                std.debug.panic("cannot deinitialize an application from its event loop", .{});
            }
            self.shutdown() catch |err| {
                // Returning would leave kernel completions pointing at storage
                // the caller is about to release.
                std.debug.panic("application shutdown failed: {}", .{err});
            };

            if (self.scheduler) |*scheduler| {
                scheduler.deinit();
            }
            self.scheduler = null;
            if (self.watcher) |*watch| watch.deinit();
            self.watcher = null;
            if (self.signal_watcher) |*watcher| watcher.deinit();
            self.signal_watcher = null;
            for (self.listeners[0..self.listener_count]) |*server| core_tcp.deinit_server(server);
            self.listener_count = 0;

            if (self.quic_transport) |*transport| transport.deinit();
            self.quic_transport = null;
            if (self.quic_tls_ctx) |*tls| tls.deinit();
            self.quic_tls_ctx = null;
            self.release_tls();
            if (self.ws_deflate) |*context| context.deinit();
            self.ws_deflate = null;
            if (self.http_compression) |*pool| pool.deinit();
            self.http_compression = null;
            for (self.static_handlers[0..self.static_handler_count]) |maybe_handler| {
                const handler = maybe_handler orelse continue;
                handler.deinit();
                std.heap.page_allocator.destroy(handler);
            }
            self.static_handler_count = 0;
            if (self.cluster_wakeup) |*wakeup| wakeup.deinit();
            self.cluster_wakeup = null;
            core_loop.deinit(&self.loop);
            // Carved pools stay inside the slab; lazily allocated RFC 7692
            // scratch is the only separately owned per-connection region.
            self.pool.deinit();
            if (self.ws_compression_owned and self.ws_compression_storage.len != 0) {
                std.heap.page_allocator.free(self.ws_compression_storage);
            }
            self.ws_compression_storage = &.{};
            self.ws_compression_owned = false;
            // The transport lives inside the slab; its rings must be unmapped
            // before the backing storage is released.
            if (self.xdp_transport) |transport| {
                transport.deinit();
                self.xdp_transport = null;
            }
            if (self.ebpf_map_fd >= 0) {
                ebpf_module.close(self.ebpf_map_fd);
                self.ebpf_map_fd = -1;
            }
            self.slab_allocator.free(self.slab);
            self.slab = &.{};
            self.deinitialized = true;
        }

        /// Stops recurring work and drains completions that borrow application
        /// slabs.
        ///
        /// Loop-thread only: from a callback it begins shutdown and lets the
        /// active run drain; from outside a run it drives the loop itself.
        /// Cross-thread callers must use `request_shutdown`, which marshals the
        /// request onto the owning loop instead of touching its completions.
        pub fn shutdown(self: *Self) !void {
            if (self.deinitialized) return error.ApplicationDeinitialized;

            self.begin_shutdown();
            if (self.running) return;

            try self.drive_shutdown();
        }

        /// Requests shutdown from any thread without touching loop state.
        ///
        /// Stores the cross-thread stop flag and wakes the run's async
        /// completion; the owning loop then runs `begin_shutdown` and drains.
        pub fn request_shutdown(self: *Self) void {
            self.cluster_stop_requested.store(true, .release);
            // Best effort: a stopping loop still observes the stop flag on
            // its next wakeup or dispatch.
            _ = self.notify_cluster();
        }

        /// Reports whether this application currently owns an active loop run.
        pub fn is_running(self: *const Self) bool {
            return self.running;
        }

        fn begin_shutdown(self: *Self) void {
            if (self.shutting_down) return;

            self.shutting_down = true;
            self.cluster_stop_requested.store(true, .release);
            // Shutdown continues even if the cross-thread wakeup is already closed.
            if (self.cluster_wakeup) |*wakeup| wakeup.notify() catch {};
            if (self.cluster_signal_watcher) |watcher| watcher.stop();
            if (self.scheduler) |*scheduler| scheduler.stop(&self.loop);
            if (self.watcher) |*watch| watch.stop(self.loop.get_xev_loop());
            if (self.signal_watcher) |*watcher| watcher.stop();
            for (self.listeners[0..self.listener_count]) |*server| {
                core_tcp.close_server(server, &self.loop);
            }
            if (self.quic_transport) |*transport| transport.shutdown();

            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index)) continue;
                core_tcp.close_connection(conn);
            }
        }

        fn drive_shutdown(self: *Self) !void {
            std.debug.assert(!self.running);
            self.running = true;
            defer self.running = false;
            try core_loop.run(&self.loop);
            try self.verify_shutdown();
        }

        fn verify_shutdown(self: *const Self) !void {
            if (self.pool.count_active() != 0) return error.ShutdownIncomplete;
            if (self.watcher) |*watch| {
                if (!watch.is_drained()) return error.ShutdownIncomplete;
            }
            if (self.signal_watcher) |*watcher| {
                if (!watcher.is_drained()) return error.ShutdownIncomplete;
            }
            for (self.listeners[0..self.listener_count]) |*server| {
                if (!server.close_complete) return error.ShutdownIncomplete;
            }
            if (self.quic_transport) |*transport| if (!transport.is_drained()) {
                return error.ShutdownIncomplete;
            };
        }

        /// Registers a synchronous GET route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.get(path, handler);
            return self;
        }

        /// Registers a synchronous HEAD route.
        pub fn head(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.head(path, handler);
            return self;
        }

        /// Registers a synchronous POST route.
        pub fn post(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.post(path, handler);
            return self;
        }

        /// Registers a synchronous PUT route.
        pub fn put(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.put(path, handler);
            return self;
        }

        /// Registers a synchronous DELETE route.
        pub fn delete(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.delete(path, handler);
            return self;
        }

        /// Registers a synchronous PATCH route.
        pub fn patch(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.patch(path, handler);
            return self;
        }

        /// Registers a synchronous OPTIONS route.
        pub fn options(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.options(path, handler);
            return self;
        }

        /// Registers a safe, idempotent RFC 10008 QUERY route.
        pub fn query(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.query(path, handler);
            return self;
        }

        /// Registers an opt-in TRACE route.
        pub fn trace(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.trace(path, handler);
            return self;
        }

        /// Registers a synchronous fallback-method route.
        pub fn any(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.any(path, handler);
            return self;
        }

        /// Registers a GET endpoint serving the current OpenAPI 3.1 document.
        pub fn openapi(self: *Self, path: []const u8) !*Self {
            return self.get_context(path, &self.router, serve_openapi);
        }

        /// Mounts a fixed-capacity JSON-RPC 2.0 service on one POST route.
        ///
        /// `service` accepts any mutable single-item pointer to a
        /// `configured_service` or `comptime_service` value that outlives the
        /// App and belongs to exactly one event loop.
        pub fn rpc(self: *Self, path: []const u8, service: anytype) !*Self {
            const Pointer = @TypeOf(service);
            const pointer = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => @compileError("RPC service must be passed by mutable pointer"),
            };
            if (pointer.size != .one or pointer.is_const) {
                @compileError("RPC service must be passed by mutable single-item pointer");
            }
            const Service = pointer.child;
            if (!@hasDecl(Service, "dispatch") or
                !@hasDecl(Service, "response_buffer") or
                !@hasDecl(Service, "seal"))
            {
                @compileError("RPC service must be created by json_rpc.configured_service");
            }

            try self.ensure_routes_mutable();
            try self.router.route_context(
                .post,
                path,
                service,
                json_rpc_http.route_handler(Service),
            );
            service.seal();
            return self;
        }

        /// Mounts one bounded, traversal-safe static asset directory.
        pub fn static(
            self: *Self,
            prefix: []const u8,
            root: []const u8,
            static_options: static_files_module.Options,
        ) !*Self {
            try self.ensure_routes_mutable();
            if (self.static_handler_count == max_static_routes) return error.StaticRouteCapacityReached;
            if (prefix.len == 0 or prefix[0] != '/' or
                std.mem.indexOfAny(u8, prefix, "?#\r\n:*") != null)
            {
                return error.InvalidRoutePath;
            }

            var route_buffer: [2048]u8 = undefined;
            const base = if (prefix.len > 1) std.mem.trimRight(u8, prefix, "/") else "";
            const route = std.fmt.bufPrint(&route_buffer, "{s}/*path", .{base}) catch {
                return error.InvalidRoutePath;
            };
            const index = self.static_handler_count;
            const handler = try std.heap.page_allocator.create(StaticFiles);
            errdefer std.heap.page_allocator.destroy(handler);
            handler.* = try StaticFiles.init(self.io, root, static_options);
            errdefer handler.deinit();
            try self.router.route_context(
                .get,
                route,
                handler,
                StaticFiles.handler,
            );
            self.static_handlers[index] = handler;
            self.static_handler_count += 1;
            return self;
        }

        /// Appends one ordered global middleware callback.
        pub fn use(
            self: *Self,
            context: *anyopaque,
            middleware: radix.MiddlewareHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.use(context, middleware);
            return self;
        }

        /// Registers a context-aware callback for one method.
        pub fn route_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_context(method, path, context, handler);
            return self;
        }

        /// Registers a deferred callback for one method.
        pub fn route_async(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async(method, path, handler);
            return self;
        }

        /// Registers a context-aware deferred callback for one method.
        pub fn route_async_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async_context(method, path, context, handler);
            return self;
        }

        /// Registers a context-aware GET route.
        pub fn get_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            return self.route_context(.get, path, context, handler);
        }

        /// Registers a deferred GET route.
        pub fn get_async(
            self: *Self,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            return self.route_async(.get, path, handler);
        }

        /// Registers a context-aware deferred GET route.
        pub fn get_async_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            return self.route_async_context(.get, path, context, handler);
        }

        /// Registers a WebSocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) !*Self {
            try self.ensure_routes_mutable();
            if (!radix.valid_ws_limits(behavior, max_ws_message_size)) {
                return error.InvalidWebSocketLimits;
            }
            if (behavior.compression == .permessage_deflate) try self.ensure_ws_compression();
            try self.router.ws(path, behavior);
            return self;
        }

        /// Registers a WebTransport datagram handler for one session path.
        ///
        /// `path` must stay valid for the application lifetime; string literals
        /// are the intended form. The application itself is the handler context
        /// unless `datagram_context` supplies another.
        pub fn datagram(
            self: *Self,
            path: []const u8,
            handler: datagram_module.Handler,
        ) !*Self {
            return self.datagram_context(path, self, handler);
        }

        /// Registers a datagram handler with explicit caller-owned context.
        pub fn datagram_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: datagram_module.Handler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.datagram_router.register(path, handler, context);
            return self;
        }

        /// Delivers one inbound WebTransport datagram to its registered path.
        ///
        /// The payload is copied into the connection ring before the handler
        /// runs; the handler receives the caller's slice, which stays valid
        /// only for the call. Returns false for an unregistered path or a full
        /// ring, and a rejected datagram increments `datagrams_dropped`.
        pub fn dispatch_datagram(
            self: *Self,
            connection_index: usize,
            session_id: u64,
            sequence_number: u64,
            path: []const u8,
            payload: []const u8,
        ) bool {
            const route = self.datagram_router.find(path) orelse return false;
            const ring = self.datagram_ring_for(connection_index) orelse return false;
            ring.push(.{
                .session_id = session_id,
                .sequence_number = sequence_number,
                .payload = payload,
            }) catch |err| switch (err) {
                error.Full => {
                    ring.note_dropped();
                    if (self.metrics_registry) |registry| registry.add(.datagrams_dropped, 1);
                    return false;
                },
                error.PayloadTooLarge, error.InvalidCapacity, error.InvalidStride => {
                    if (self.metrics_registry) |registry| registry.add(.datagrams_dropped, 1);
                    return false;
                },
            };
            if (self.metrics_registry) |registry| registry.add(.datagrams_received, 1);
            route.handler(route.context, session_id, payload);
            return true;
        }

        /// Removes the oldest queued datagram for one connection.
        pub fn next_datagram(
            self: *Self,
            connection_index: usize,
        ) ?datagram_ring_module.DatagramView {
            const ring = self.datagram_ring_for(connection_index) orelse return null;
            return ring.pop();
        }

        /// Returns the fixed-capacity registry, or null when observability is
        /// disabled in the configuration.
        pub fn metrics(self: *Self) ?*metrics_module.Registry {
            return self.metrics_registry;
        }

        fn datagram_ring_for(self: *Self, connection_index: usize) ?*DatagramRing {
            if (connection_index >= self.datagram_rings.len) return null;
            return &self.datagram_rings[connection_index];
        }

        fn ensure_routes_mutable(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.routes_locked) return error.RoutesLocked;
            try self.ensure_router();
        }

        /// Binds the slab-backed router storage on first route work.
        ///
        /// A pre-bound router (an initialized `router` injected by tests or
        /// callers) wins over lazy binding.
        fn ensure_router(self: *Self) !void {
            if (self.router_bound or self.router.node_count != 0) return;
            self.router = try radix.Router.init(self.router_storage);
            self.router_bound = true;
        }

        /// Installs the hidden metrics route once, before routes are locked.
        fn install_observability(self: *Self) !void {
            if (!self.metrics_enabled or self.metrics_registry == null) return;
            if (self.metrics_installed) return;
            _ = try self.get_context(self.metrics_path, self, serve_metrics);
            self.metrics_installed = true;
        }

        fn ensure_ws_compression(self: *Self) !void {
            if (self.ws_deflate != null) return;

            if (self.ws_compression_storage.len != 0) {
                // ServerConfig pre-reserved paired scratch inside the startup slab.
                self.ws_deflate = try init_ws_deflate(
                    self.ws_compression_capacity,
                    max_ws_message_size,
                );
                return;
            }

            var context = try DeflateContext.init(6);
            errdefer context.deinit();
            const per_connection = try context.scratch_bound(max_ws_message_size);

            const per_connection_storage = std.math.mul(
                usize,
                per_connection,
                2,
            ) catch return error.SizeOverflow;
            const storage_len = std.math.mul(
                usize,
                max_connections,
                per_connection_storage,
            ) catch return error.SizeOverflow;
            const storage = try std.heap.page_allocator.alloc(u8, storage_len);

            self.ws_compression_capacity = per_connection;
            self.ws_compression_storage = storage;
            self.ws_compression_owned = true;
            self.ws_deflate = context;
        }

        /// Opens the per-worker compressor pool and validates scratch capacity.
        fn init_ws_deflate(capacity: usize, message_capacity: usize) !DeflateContext {
            var context = try DeflateContext.init(6);
            errdefer context.deinit();
            const per_connection = try context.scratch_bound(message_capacity);
            if (per_connection > capacity) return error.CompressionScratchTooSmall;
            return context;
        }

        /// Returns one connection's borrowed slices of the shared extra-header
        /// pointer region; empty when the configuration matches inline capacity.
        fn connection_header_extras(self: *Self, connection_index: usize) HeaderExtras {
            if (self.extra_header_capacity == 0) return .{ .names = &.{}, .values = &.{} };

            // A runtime slice cannot prove alignment; the layout aligned this
            // region to the boundary, so re-assert it for the pointer reinterpret.
            const start = connection_index * self.extra_header_stride;
            const bytes: []align(config_module.request_buffer_alignment) u8 = @alignCast(
                self.header_extras[start .. start + self.extra_header_stride],
            );
            const pointers = std.mem.bytesAsSlice([]const u8, bytes);
            return .{
                .names = pointers[0..self.extra_header_capacity],
                .values = pointers[self.extra_header_capacity .. self.extra_header_capacity * 2],
            };
        }

        /// Returns one connection's borrowed slices of the shared extra
        /// route-capture pointer region; empty when the configuration matches
        /// inline capacity.
        fn connection_route_param_extras(self: *Self, connection_index: usize) RouteParamExtras {
            if (self.extra_route_param_capacity == 0) {
                return .{ .names = &.{}, .values = &.{} };
            }

            // A runtime slice cannot prove alignment; the layout aligned this
            // region to the boundary, so re-assert it for the pointer reinterpret.
            const start = connection_index * self.extra_route_param_stride;
            const bytes: []align(@alignOf([]const u8)) u8 = @alignCast(
                self.route_param_extras[start .. start + self.extra_route_param_stride],
            );
            const pointers = std.mem.bytesAsSlice([]const u8, bytes);
            return .{
                .names = pointers[0..self.extra_route_param_capacity],
                .values = pointers[self.extra_route_param_capacity .. self.extra_route_param_capacity * 2],
            };
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_heartbeat_tick(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.shutting_down) return;
            const now = std.Io.Clock.now(.awake, self.io);
            const now_ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index) or conn.closing) continue;
                conn.ws.heartbeat_tick(now_ms);
            }
            if (self.shutting_down) return;
            if (self.scheduler) |*scheduler| {
                scheduler.schedule_after(&self.heartbeat_timer, 5000, on_heartbeat_tick, self);
            }
        }

        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const binding: *const ListenerBinding = @ptrCast(@alignCast(user_data.?));
            const self = binding.app;
            if (self.shutting_down) {
                close_socket_now(socket);
                return;
            }
            const conn = self.pool.acquire() orelse {
                // No I/O was registered for this descriptor, so direct close is safe.
                close_socket_now(socket);
                return;
            };

            // acquire only returns pointers into this pool's contiguous slab.
            const connection_index = self.pool.index_of(conn) orelse unreachable;
            const extras = self.connection_header_extras(connection_index);
            const route_params = self.connection_route_param_extras(connection_index);
            conn.req = .{};
            conn.route_param_names = route_params.names;
            conn.route_param_values = route_params.values;
            conn.parser = .{
                .max_body_size = self.max_body_size,
                .max_request_line_bytes = self.max_request_line_size,
                .max_header_bytes = self.max_header_size,
                .extra_header_names = extras.names,
                .extra_header_values = extras.values,
            };
            const h2_start = connection_index * self.h2_session_stride;
            const h2_region = self.h2_sessions[h2_start .. h2_start + self.h2_session_stride];
            const h2_storage = core_tcp.Http2Session.carve_storage(
                h2_region,
                self.h2_capacities,
            ) catch {
                _ = self.pool.release(conn);
                close_socket_now(socket);
                return;
            };
            conn.h2 = core_tcp.Http2Session.init(h2_storage) catch {
                _ = self.pool.release(conn);
                close_socket_now(socket);
                return;
            };
            conn.reset_protocol() catch {
                _ = self.pool.release(conn);
                close_socket_now(socket);
                return;
            };
            // HTTP/2 bodies share the HTTP/1 configured ceiling; the compiled
            // session slab remains the hard capacity when the config is larger.
            conn.h2.request_body_limit = self.max_body_size;
            conn.ssl = null;
            conn.network_bio = null;
            conn.is_tls_handshake_done = false;
            conn.tls_shutdown_started = false;
            conn.read_active = false;
            conn.read_cancel_active = false;
            conn.write_cancel_active = false;
            conn.request_len = 0;
            conn.write_head = 0;
            conn.write_len = 0;
            conn.write_in_flight_len = 0;
            conn.is_writing = false;
            conn.close_complete = false;
            conn.was_backpressured = false;
            conn.close_when_drained = false;
            conn.closing = false;
            conn.expect_continue_sent = false;
            conn.suppress_response_body = false;
            conn.dispatch_suspended = false;
            conn.pending_request_consumed = 0;
            conn.pending_close_requested = false;
            conn.write_batch_depth = 0;
            conn.async_response_state.cancel();

            const now = std.Io.Clock.now(.awake, self.io);
            conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

            conn.socket = socket;
            conn.loop = &self.loop.xev_loop;
            const request_start = connection_index * self.request_buffer_stride;
            conn.request_buffer = self.request_buffers[request_start .. request_start + self.request_buffer_stride];
            conn.reject_policy = &self.reject_policy;
            const message_start = connection_index * max_ws_message_size;
            conn.ws_message_buffer = self.ws_message_storage[message_start .. message_start + max_ws_message_size];
            if (self.ws_deflate) |*context| {
                const buffers = compression_buffers(
                    self.ws_compression_storage,
                    self.ws_compression_capacity,
                    connection_index,
                ) orelse unreachable;
                conn.ws_compression_buffer = buffers.incoming;
                conn.ws_compression_output_buffer = buffers.outgoing;
                conn.ws_deflate = context;
            } else {
                conn.ws_compression_buffer = &.{};
                conn.ws_compression_output_buffer = &.{};
                conn.ws_deflate = null;
            }
            conn.http_compression = if (self.http_compression) |*pool| pool else null;
            const write_start = connection_index * write_queue_size;
            conn.write_queue = self.write_queue_storage[write_start .. write_start + write_queue_size];
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            conn.pool_ptr = &self.pool;
            conn.io = self.io;
            conn.metrics = self.metrics_registry;
            if (self.scheduler) |*scheduler| {
                conn.attach_timer_scheduler(
                    scheduler,
                    idle_timeout_ms,
                    self.header_timeout_ms,
                );
            }
            if (self.metrics_registry) |registry| registry.add(.connections_accepted, 1);
            if (self.dev_log_enabled) {
                const sink = dev_log_module.thread_sink();
                conn.dev_log = sink;
                sink.record(.{
                    .timestamp_ms = dev_log_module.now_ms(self.io),
                    .level = .info,
                    .direction = .data_in,
                    .event = .{ .connection_opened = .{ .index = connection_index } },
                });
            } else {
                conn.dev_log = null;
            }
            conn.on_close_cb = (struct {
                fn cb(pool_ptr: *anyopaque, c: *core_tcp.TcpConnection) void {
                    const pool: *Pool = @ptrCast(@alignCast(pool_ptr));
                    if (c.metrics) |registry| registry.add(.connections_closed, 1);
                    if (c.dev_log) |sink| {
                        sink.record(.{
                            .timestamp_ms = dev_log_module.now_ms(c.io),
                            .level = .info,
                            .direction = .data_out,
                            .event = .{
                                .connection_closed = .{
                                    .index = pool.index_of(c) orelse 0,
                                },
                            },
                        });
                    }
                    _ = pool.release(c);
                }
            }).cb;

            if (binding.tls) {
                const tls = self.tls_ctx orelse {
                    core_tcp.close_connection(conn);
                    return;
                };
                conn.init_tls(tls.ctx) catch {
                    core_tcp.close_connection(conn);
                    return;
                };
            }
            core_tcp.read_start(conn, &self.loop);
        }

        /// Binds one TCP listener and starts accepting.
        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            return self.listen_all(&.{.{ .address = address, .port = port }});
        }

        /// Binds every endpoint, verifies the bindings, then starts accepting.
        ///
        /// No accept completion is armed until every socket in `endpoints` has
        /// bound and reported a local port. A failure closes the sockets bound
        /// by this call and leaves routes unlocked, so startup is all-or-none.
        pub fn listen_all(self: *Self, endpoints: []const TcpListenEndpoint) !void {
            return self.listen_all_options(endpoints, false);
        }

        fn listen_all_options(
            self: *Self,
            endpoints: []const TcpListenEndpoint,
            reuse_port: bool,
        ) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.listener_count != 0) return error.AlreadyListening;
            if (endpoints.len == 0) return error.EmptyListenerSet;
            if (endpoints.len > max_tcp_listeners) return error.ListenerCapacityReached;
            for (endpoints) |endpoint| {
                const use_tls = endpoint.tls orelse (self.tls_ctx != null);
                if (use_tls and self.tls_ctx == null) return error.TlsNotInitialized;
            }
            try self.ensure_router();
            // Register the metrics route before any fallible resource is
            // allocated so a failure cannot strand a socket or timer.
            try self.install_observability();

            var bound: usize = 0;
            errdefer {
                for (self.listeners[0..bound]) |*server| {
                    core_tcp.deinit_server(server);
                    close_socket_now(server.listener);
                }
            }

            // Phase 1: bind every endpoint without arming any accept.
            for (endpoints, 0..) |endpoint, index| {
                const use_tls = endpoint.tls orelse (self.tls_ctx != null);
                self.bindings[index] = .{ .app = self, .tls = use_tls };
                self.listeners[index] = if (reuse_port)
                    try core_tcp.init_reuse_port_server(
                        endpoint.address,
                        endpoint.port,
                        on_new_connection,
                        &self.bindings[index],
                    )
                else
                    try core_tcp.init_server(
                        endpoint.address,
                        endpoint.port,
                        on_new_connection,
                        &self.bindings[index],
                    );
                bound += 1;
            }

            // Phase 2: the barrier. Every kernel socket must report a usable
            // local address before port 8080 (or any other listener) accepts.
            for (self.listeners[0..bound]) |*server| {
                _ = try core_tcp.listener_port(server);
            }

            // The wheel also backs `AsyncResponse.sleep`, so it exists even
            // when both idle deadlines are disabled.
            var scheduler: ?core_timer.Scheduler = try core_timer.Scheduler.init(self.io);
            errdefer {
                if (scheduler) |*engine| engine.deinit();
            }

            // Phase 3: publish state, then arm accepts for the whole set.
            self.listener_count = bound;
            self.routes_locked = true;
            self.scheduler = scheduler;
            for (self.listeners[0..bound]) |*server| {
                core_tcp.accept_start(server, &self.loop);
            }
            if (self.scheduler) |*engine| {
                engine.start(&self.loop);
                if (self.router.has_ws_heartbeats()) {
                    engine.schedule_after(&self.heartbeat_timer, 5000, on_heartbeat_tick, self);
                }
            }

            for (endpoints) |endpoint| {
                const scheme = if (endpoint.tls orelse (self.tls_ctx != null)) "https" else "http";
                if (!self.write_ready_summary(
                    scheme,
                    endpoint.address,
                    endpoint.port,
                )) {
                    log.info("server listening on {s}:{d}", .{ endpoint.address, endpoint.port });
                }
            }
        }

        /// Binds and starts the UDP/QUIC listener, locking route mutation.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (!self.http3_enabled or self.quic_tls_ctx == null) return error.Http3NotInitialized;
            if (self.quic_transport != null) return error.AlreadyListening;
            // lsxpack field lengths are u16. HTTP/1.1 and HTTP/2 may still use
            // a larger shared header limit; only HTTP/3 activation is bounded.
            if (self.max_header_size > std.math.maxInt(u16)) return error.InvalidHttp3Capacity;
            try self.ensure_router();
            // Register the metrics route before the transport exists, so an
            // install failure can never strand a started transport.
            try self.install_observability();

            self.quic_transport = try QuicTransport.init(
                self.quic_tls_ctx.?.ctx,
                &self.router,
                address,
                port,
            );
            // A failed start leaves the transport unstarted, so deinit is safe.
            errdefer {
                if (self.quic_transport) |*transport| transport.deinit();
                self.quic_transport = null;
            }
            try self.quic_transport.?.start(self.loop.get_xev_loop());

            self.routes_locked = true;

            if (!self.write_ready_summary("https", address, port)) {
                log.info("http/3 server listening on {s}:{d}", .{ address, port });
            }
        }

        /// Runs the event loop until shutdown completes or no work remains.
        pub fn run(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.running) return error.ApplicationAlreadyRunning;

            self.running = true;
            defer self.running = false;
            // Apps that never call a listen function still get the wordmark.
            self.write_startup_banner();
            try self.start_file_watch();
            // Every run owns a wakeup so request_shutdown works from any thread,
            // not only for cluster members.
            if (self.cluster_wakeup == null) {
                self.cluster_wakeup = try xev.Async.init();
            }
            self.arm_cluster_wakeup();
            // A request that raced the arm must not block the loop forever.
            if (self.cluster_stop_requested.load(.acquire)) self.begin_shutdown();
            try core_loop.run(&self.loop);
            self.flush_dev_log();
            if (self.shutting_down) try self.verify_shutdown();
        }

        /// Arms graceful shutdown on SIGINT and SIGTERM for this application.
        ///
        /// Call before `run`; a received signal requests the same shutdown as
        /// `App.shutdown`. Calling after shutdown starts or after `deinit`
        /// returns `error.ApplicationUnavailable`; a second call returns
        /// `error.SignalWatcherAlreadyInstalled`. `begin_shutdown` stops the
        /// watcher, and `deinit` releases it after the loop has drained.
        pub fn catch_shutdown_signals(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) {
                return error.ApplicationUnavailable;
            }
            if (self.signal_watcher != null) return error.SignalWatcherAlreadyInstalled;
            self.signal_watcher = try core_signal.SignalWatcher.init(
                &self.loop,
                on_shutdown_signal,
                self,
            );
            self.signal_watcher.?.start();
        }

        /// Bridges a coalesced signal wakeup into the shared shutdown path.
        fn on_shutdown_signal(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.begin_shutdown();
        }

        /// Arms the recursive file watcher configured for the dev log.
        fn start_file_watch(self: *Self) !void {
            if (self.watch_paths.len == 0) return;
            self.watcher = .{};
            self.watcher.?.start(self.io, self.loop.get_xev_loop(), self.watch_paths) catch |err| {
                self.watcher = null;
                return err;
            };
        }

        /// Writes this worker's startup wordmark once, before the first
        /// listening line and sized to the output terminal.
        fn write_startup_banner(self: *Self) void {
            if (!self.enable_dev_log_sink()) return;
            const sink = dev_log_module.thread_sink();
            sink.record_banner(terminal_module.columns(sink.file));
        }

        /// Enables this worker's dev-log sink, unless the default stderr sink
        /// is not a terminal; returns false while the sink stays silent.
        ///
        /// Keeping redirected runs quiet means piping, log capture, and the
        /// throughput benchmark are not slowed by per-record writes. An
        /// explicit `set_dev_log_file` always records.
        fn enable_dev_log_sink(self: *Self) bool {
            if (!self.dev_log_enabled) return false;
            const file = self.dev_log_file orelse std.Io.File.stderr();
            if (self.dev_log_file == null) {
                const interactive = file.isTty(self.io) catch false;
                if (!interactive) return false;
            }
            dev_log_module.thread_sink().enable(self.io, file);
            return true;
        }

        /// Writes the wordmark and the Vite-style ready summary for one bound
        /// listener; returns false when the log is disabled or its default
        /// sink is not a terminal.
        fn write_ready_summary(
            self: *Self,
            scheme: []const u8,
            address: []const u8,
            port: u16,
        ) bool {
            if (!self.dev_log_enabled) return false;
            self.write_startup_banner();
            const sink = dev_log_module.thread_sink();
            if (!sink.enabled) return false;
            const host = dev_log_module.display_host(address);
            sink.record_ready(.{
                .elapsed_ns = self.ready_elapsed_ns(),
                .scheme = scheme,
                .host = host,
                .host_is_ipv6 = std.mem.indexOfScalar(u8, host, ':') != null,
                .port = port,
            });
            return true;
        }

        /// Nanoseconds between application construction and listener startup.
        fn ready_elapsed_ns(self: *const Self) u64 {
            const now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
            if (now_ns <= 0) return 0;
            const now: u64 = @intCast(now_ns);
            return now -| self.ready_started_ns;
        }

        /// Overrides the development-log output file; defaults to stderr.
        ///
        /// Call it before `listen` or `run` so the startup wordmark uses it.
        /// An explicitly bound file always records, even when stderr is not a
        /// terminal.
        pub fn set_dev_log_file(self: *Self, file: std.Io.File) void {
            self.dev_log_file = file;
        }

        /// Writes any pending development-log bytes for this worker.
        pub fn flush_dev_log(self: *Self) void {
            if (!self.dev_log_enabled) return;
            _ = dev_log_module.thread_sink().flush();
        }

        /// Records every counter of the hidden registry in this worker's log.
        pub fn log_metrics(self: *Self) void {
            if (!self.dev_log_enabled) return;
            const registry = self.metrics_registry orelse return;
            const sink = dev_log_module.thread_sink();
            sink.record_metrics(dev_log_module.now_ms(self.io), .data_out, registry);
        }

        /// Publishes one message to every matching bounded subscription.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) usize {
            return self.pubsub.publish(topic, message, is_text);
        }

        /// Returns a heap-backed thread-per-core manager for this App type.
        pub fn cluster(comptime capacity: usize) type {
            if (capacity == 0) @compileError("cluster worker count must be greater than zero");

            return struct {
                const Cluster = @This();

                /// Concrete application type every worker owns.
                pub const Worker = Self;
                /// Route configuration callback applied to every worker.
                pub const ConfigureCallback = *const fn (*Worker, usize) anyerror!void;

                /// PEM credential paths loaded into every worker's TLS context.
                const PemCredentials = struct {
                    cert_path: [:0]const u8,
                    key_path: [:0]const u8,
                };

                /// Where one worker's TLS context credentials come from.
                const TlsCredentialSource = union(enum) {
                    pem_files: PemCredentials,
                    ephemeral: void,
                };

                allocator: std.mem.Allocator,
                workers: []Self,
                inboxes: []ClusterInbox,
                threads: []std.Thread,
                /// Compatibility field; `run` snapshots it at start. New code
                /// should use `ClusterOptions.worker_count` or an explicit
                /// worker-count constructor.
                active_workers: usize = capacity,
                /// Compatibility mirror; updated by `run`/`join`.
                thread_count: usize = 0,
                /// Compatibility mirror; `first_failure()` is authoritative.
                worker_failed: std.atomic.Value(bool) = .init(false),
                startup_options: ClusterOptions = .{},
                cores: core_affinity.CoreSelection = .{},
                signal_watcher: ?core_signal.SignalWatcher = null,
                /// Compatibility mirror; not a synchronization primitive.
                /// `state()` is authoritative for lifecycle decisions.
                deinitialized: bool = false,
                group: worker_group_module.worker_group(Cluster) = .{},

                pub fn init(allocator: std.mem.Allocator, io: std.Io) !Cluster {
                    return init_with_options(allocator, io, default_config, .{});
                }

                /// Builds every worker slab on this thread with `config`; each
                /// worker then owns its slab exclusively for its whole lifetime.
                pub fn init_with_options(
                    allocator: std.mem.Allocator,
                    io: std.Io,
                    comptime config: config_module.ServerConfig,
                    startup_options: ClusterOptions,
                ) !Cluster {
                    const active_count = try cluster_module.resolve_worker_count(
                        capacity,
                        startup_options,
                    );
                    return init_with_worker_count(
                        allocator,
                        io,
                        config,
                        startup_options,
                        active_count,
                    );
                }

                /// Builds `active_count` workers inside the compiled capacity.
                ///
                /// `active_count` wins over `startup_options.worker_count`; the
                /// options constructor uses the option when one is set. Only
                /// active workers allocate slabs, inboxes, and thread handles.
                /// Values outside the capacity fail before allocation.
                pub fn init_with_worker_count(
                    allocator: std.mem.Allocator,
                    io: std.Io,
                    comptime config: config_module.ServerConfig,
                    startup_options: ClusterOptions,
                    active_count: usize,
                ) !Cluster {
                    const resolved_count = try cluster_module.validate_worker_count(
                        active_count,
                        capacity,
                    );
                    const workers = try allocator.alloc(Self, resolved_count);
                    errdefer allocator.free(workers);
                    const inboxes = try allocator.alloc(ClusterInbox, resolved_count);
                    errdefer allocator.free(inboxes);
                    const threads = try allocator.alloc(std.Thread, resolved_count);
                    errdefer allocator.free(threads);
                    for (inboxes) |*inbox| inbox.* = .{};

                    var initialized: usize = 0;
                    errdefer {
                        for (workers[0..initialized]) |*app_worker| app_worker.deinit();
                    }
                    for (workers, 0..) |*app_worker, index| {
                        app_worker.* = try Self.init_configured(io, allocator, config);
                        initialized += 1;
                        try app_worker.attach_cluster_inbox(&inboxes[index]);
                    }
                    return .{
                        .allocator = allocator,
                        .workers = workers,
                        .inboxes = inboxes,
                        .threads = threads,
                        .active_workers = resolved_count,
                        .startup_options = startup_options,
                        .cores = core_affinity.CoreSelection.init(),
                        .group = .{ .active = std.atomic.Value(usize).init(resolved_count) },
                    };
                }

                /// Releases the cluster; panics if `run` is still active.
                ///
                /// Supervisors that cannot accept a panic use
                /// `deinit_checked` and handle `error.ClusterRunning`.
                pub fn deinit(self: *Cluster) void {
                    self.deinit_checked() catch |err| switch (err) {
                        error.ClusterRunning => std.debug.panic(
                            "cannot deinitialize a running cluster",
                            .{},
                        ),
                    };
                }

                /// Releases the cluster and returns a typed lifecycle error.
                ///
                /// The call claims release once. A second caller waits until
                /// the winning owner publishes `released`, then returns.
                pub fn deinit_checked(self: *Cluster) cluster_module.ReleaseError!void {
                    if (!try self.group.begin_release()) {
                        self.group.wait_released();
                        return;
                    }
                    // No new external call can enter after the release claim.
                    // Wait for calls that entered before it, then free.
                    self.group.wait_idle();
                    // Publish the compatibility mirror before storage moves.
                    // It is informational, not a synchronization primitive.
                    self.deinitialized = true;
                    self.group.set_active(0);
                    self.stop_signal_watcher();
                    // App.deinit closes recurring work and drives each loop
                    // until drained, which also processes the watcher stop.
                    for (self.workers) |*app_worker| app_worker.deinit();
                    self.release_signal_watcher();

                    const threads = self.threads;
                    const inboxes = self.inboxes;
                    const workers = self.workers;
                    self.threads = &.{};
                    self.inboxes = &.{};
                    self.workers = &.{};
                    self.active_workers = 0;
                    self.thread_count = 0;

                    self.allocator.free(threads);
                    self.allocator.free(inboxes);
                    self.allocator.free(workers);
                    self.group.finish_release();
                }

                /// Applies the same route configuration callback to every worker.
                ///
                /// The callback runs before any thread starts. A callback error
                /// stops configuration at that worker and leaves earlier route
                /// registrations in place. Do not call `run` or `deinit_checked`
                /// from the callback; this call already holds an in-flight
                /// registration and release would wait on it.
                pub fn configure(
                    self: *Cluster,
                    comptime callback: ConfigureCallback,
                ) !void {
                    if (!self.group.enter()) return error.ClusterDeinitialized;
                    defer self.group.leave();
                    try self.group.require_configured();
                    for (self.workers, 0..) |*app_worker, index| {
                        try callback(app_worker, index);
                    }
                }

                /// Returns one worker by index, or null outside the active set.
                ///
                /// The pointer is borrowed and does not keep the group alive.
                /// External synchronization is required if another thread can
                /// call `deinit_checked` while the pointer is retained.
                pub fn worker(self: *Cluster, index: usize) ?*Self {
                    switch (self.group.state()) {
                        .releasing, .released => return null,
                        .configured, .running, .stopped => {},
                    }
                    if (index >= self.workers.len) return null;
                    return &self.workers[index];
                }

                /// Active worker count, snapshotted by `run`; before the first
                /// run this is the configured count.
                pub fn worker_count(self: *const Cluster) usize {
                    return self.group.active_count();
                }

                /// Compiled worker capacity.
                pub fn worker_capacity(self: *const Cluster) usize {
                    _ = self;
                    return capacity;
                }

                /// Current lifecycle state.
                pub fn state(self: *const Cluster) cluster_module.ClusterState {
                    return self.group.state();
                }

                /// First worker or spawn error, or null while every worker is healthy.
                ///
                /// The value stays available after `run` returns so a supervisor
                /// can report the failing worker instead of a bare error name.
                pub fn first_failure(self: *Cluster) ?cluster_module.WorkerFailure {
                    return self.group.failure();
                }

                /// Number of failures recorded since the last `run`.
                pub fn failure_count(self: *Cluster) usize {
                    return self.group.failure_count();
                }

                /// Loads `cert_path`/`key_path` into one TLS context owned by each worker.
                ///
                /// Call once after `configure` and before `listen`; the supported order is
                /// build_cluster -> configure -> enable_https -> listen -> run. Every worker
                /// keeps its own context, so no TLS state is shared between loops. On any
                /// failure the contexts this call created are released and the call is
                /// retryable.
                ///
                /// Fails with `error.ClusterDeinitialized` after `deinit`,
                /// `error.ClusterRunning` while `run` is active,
                /// `error.ClusterStopped` after `run` returned,
                /// `error.AlreadyListening` after `listen`, and
                /// `error.TlsAlreadyEnabled` on a repeated call. Credential
                /// failures (`CertificateLoadFailed`, `PrivateKeyLoadFailed`)
                /// come from `TlsContext.init`; BoringSSL rejects a key that
                /// does not match the certificate during key load, so a PEM
                /// mismatch also reports `PrivateKeyLoadFailed`.
                pub fn enable_https(
                    self: *Cluster,
                    cert_path: [:0]const u8,
                    key_path: [:0]const u8,
                ) !void {
                    return self.install_worker_tls(.{ .pem_files = .{
                        .cert_path = cert_path,
                        .key_path = key_path,
                    } });
                }

                /// Generates one self-signed certificate per worker for development.
                ///
                /// Use `enable_https` with PEM files in production; generated certificates
                /// differ per worker and live only for the process.
                pub fn enable_https_ephemeral(self: *Cluster) !void {
                    return self.install_worker_tls(.{ .ephemeral = {} });
                }

                fn install_worker_tls(self: *Cluster, source: TlsCredentialSource) !void {
                    if (!self.group.enter()) return error.ClusterDeinitialized;
                    defer self.group.leave();
                    try self.group.require_configured();

                    var created: usize = 0;
                    errdefer for (self.workers[0..created]) |*app_worker| app_worker.release_tls();
                    for (self.workers) |*app_worker| {
                        if (app_worker.shutting_down or app_worker.deinitialized) {
                            return error.ApplicationUnavailable;
                        }
                        if (app_worker.listener_count != 0) return error.AlreadyListening;
                        if (app_worker.tls_ctx != null) return error.TlsAlreadyEnabled;
                        app_worker.tls_ctx = switch (source) {
                            .pem_files => |credentials| try TlsContext.init(
                                credentials.cert_path,
                                credentials.key_path,
                            ),
                            .ephemeral => try TlsContext.init_ephemeral(.{}),
                        };
                        created += 1;
                    }
                }

                /// Binds every worker to one shared kernel port.
                pub fn listen(self: *Cluster, address: []const u8, port: u16) !void {
                    if (!self.group.enter()) return error.ClusterDeinitialized;
                    defer self.group.leave();
                    try self.group.require_configured();

                    var listening: usize = 0;
                    errdefer {
                        // Best effort: preserve the original bind error while
                        // releasing the listeners created by this call.
                        for (self.workers[0..listening], 0..) |*app_worker, index| {
                            app_worker.shutdown() catch |err| {
                                log.warn("worker {d} listen cleanup failed: {s}", .{
                                    index,
                                    @errorName(err),
                                });
                            };
                        }
                    }
                    for (self.workers) |*app_worker| {
                        try app_worker.listen_reuse_port(address, port);
                        listening += 1;
                    }
                }

                /// Broadcasts through bounded per-worker queues and wakes each loop.
                ///
                /// Kept for source compatibility; returns the accepted count.
                /// Use `publish_report` when the caller must observe dropped
                /// inboxes or failed loop wakeups.
                pub fn publish(
                    self: *Cluster,
                    topic: []const u8,
                    message: []const u8,
                    is_text: bool,
                ) cluster_module.PublishError!usize {
                    const report = try self.publish_report(topic, message, is_text);
                    return report.queued;
                }

                /// Broadcasts and reports accepted, dropped, and unwoken workers.
                pub fn publish_report(
                    self: *Cluster,
                    topic: []const u8,
                    message: []const u8,
                    is_text: bool,
                ) cluster_module.PublishError!cluster_module.PublishReport {
                    if (!self.group.enter()) return error.ClusterDeinitialized;
                    defer self.group.leave();
                    try self.group.require_publishable();
                    return ClusterInbox.broadcast(
                        self.inboxes,
                        topic,
                        message,
                        is_text,
                        self,
                        notify_worker,
                    );
                }

                fn notify_worker(context: *anyopaque, index: usize) bool {
                    const self: *Cluster = @ptrCast(@alignCast(context));
                    return self.workers[index].notify_cluster_delivery();
                }

                /// Runs all workers on native threads and joins them on shutdown.
                ///
                /// A spawn failure requests shutdown for the workers already
                /// started, joins them, and returns the original OS error.
                /// A worker event-loop or post-run cleanup failure returns
                /// `error.ClusterWorkerFailed` and remains available through
                /// `first_failure`.
                pub fn run(self: *Cluster) cluster_module.RunError!void {
                    try self.group.begin_run();

                    // Publish `stopped` after cleanup stops the watcher and
                    // drains every worker loop. If a drain fails, deinit
                    // releases the surviving watcher after the loops are
                    // destroyed, so a supervisor still owns a safe free path.
                    defer self.group.finish_run();

                    const spawn_count = self.active_workers;
                    if (spawn_count == 0 or spawn_count > self.threads.len) {
                        return error.InvalidWorkerCount;
                    }
                    self.group.set_active(spawn_count);
                    self.worker_failed.store(false, .release);
                    var spawn_error: ?std.Thread.SpawnError = null;
                    self.group.start(
                        self.threads,
                        spawn_count,
                        self,
                        worker_main,
                    ) catch |err| {
                        if (self.group.failure()) |failure| {
                            log.warn("worker {d} ({s}) failed to start: {s}", .{
                                failure.index,
                                @tagName(failure.phase),
                                @errorName(failure.err),
                            });
                        } else {
                            log.warn("worker group failed to start: {s}", .{
                                @errorName(err),
                            });
                        }
                        spawn_error = switch (err) {
                            error.ThreadQuotaExceeded,
                            error.SystemResources,
                            error.OutOfMemory,
                            error.LockedMemoryLimitExceeded,
                            error.Unexpected,
                            => |spawn_err| spawn_err,
                            // A valid run path cannot reach these lifecycle
                            // preconditions; keep the terminal type finite.
                            error.InvalidWorkerCount,
                            error.WorkerGroupAlreadyRunning,
                            error.WorkerGroupNotRunning,
                            => error.Unexpected,
                        };
                        self.request_shutdown();
                    };

                    self.thread_count = self.group.started_count();
                    self.group.join(self.threads);
                    self.thread_count = 0;
                    self.cleanup_workers();

                    if (spawn_error) |err| {
                        self.worker_failed.store(true, .release);
                        return err;
                    }
                    if (self.group.failure() != null) {
                        self.worker_failed.store(true, .release);
                        return error.ClusterWorkerFailed;
                    }
                }

                /// Stops recurring work and drains every joined worker loop.
                fn cleanup_workers(self: *Cluster) void {
                    self.stop_signal_watcher();
                    for (self.workers, 0..) |*app_worker, index| {
                        app_worker.shutdown() catch |err| {
                            self.group.record_failure(index, .cleanup, err);
                            self.worker_failed.store(true, .release);
                            log.warn("worker {d} cleanup failed: {s}", .{
                                index,
                                @errorName(err),
                            });
                        };
                    }
                    self.drain_signal_watcher();
                }

                /// Requests event-loop-confined shutdown for every worker.
                ///
                /// After `deinit` this is a documented no-op: the worker
                /// slices are released, so there is no loop left to wake and
                /// no resource to drain. The guard makes the behavior explicit
                /// at the call site instead of relying on an empty slice.
                pub fn request_shutdown(self: *Cluster) void {
                    if (!self.group.enter()) return;
                    defer self.group.leave();
                    switch (self.group.state()) {
                        .releasing, .released, .stopped => return,
                        .configured, .running => {},
                    }
                    for (self.workers) |*app_worker| app_worker.request_shutdown();
                }

                /// Installs one process-wide shutdown watcher on the first worker.
                ///
                /// The callback requests shutdown for every worker, so one
                /// SIGINT or SIGTERM drains the whole group. Returns
                /// `error.SignalWatcherAlreadyInstalled` while any watcher owns
                /// the process-wide handler state.
                pub fn catch_shutdown_signals(self: *Cluster) !void {
                    if (!self.group.enter()) return error.ClusterDeinitialized;
                    defer self.group.leave();
                    try self.group.require_configured();
                    if (self.signal_watcher != null) return error.SignalWatcherAlreadyInstalled;
                    self.signal_watcher = try core_signal.SignalWatcher.init(
                        &self.workers[0].loop,
                        on_cluster_shutdown_signal,
                        self,
                    );
                    self.signal_watcher.?.start();
                    if (self.signal_watcher) |*watcher| {
                        self.workers[0].cluster_signal_watcher = watcher;
                    }
                }

                /// Disarms the cluster watcher before worker loops are drained.
                fn stop_signal_watcher(self: *Cluster) void {
                    if (self.signal_watcher) |*watcher| {
                        watcher.stop();
                        self.workers[0].cluster_signal_watcher = null;
                    }
                }

                /// Drains a stopped watcher while the first worker loop still exists.
                fn drain_signal_watcher(self: *Cluster) void {
                    const watcher = &(self.signal_watcher orelse return);
                    if (watcher.is_drained()) {
                        watcher.deinit();
                        self.signal_watcher = null;
                        return;
                    }
                    // Worker shutdown has already closed recurring work, so
                    // this loop has only the stop wakeup left to process.
                    self.workers[0].loop.get_xev_loop().run(.until_done) catch |err| {
                        log.warn("cluster signal watcher drain failed: {s}", .{
                            @errorName(err),
                        });
                        // Keep the watcher; deinit releases it after the
                        // worker loops are destroyed and cannot run again.
                        return;
                    };
                    if (watcher.is_drained()) {
                        watcher.deinit();
                        self.signal_watcher = null;
                    }
                }

                /// Releases the watcher after every worker loop is destroyed.
                fn release_signal_watcher(self: *Cluster) void {
                    const watcher = &(self.signal_watcher orelse return);
                    if (watcher.is_drained()) {
                        watcher.deinit();
                    } else {
                        // The loop cannot run again, so the undrained release
                        // is safe here.
                        watcher.deinit_undrained();
                    }
                    self.signal_watcher = null;
                }

                fn on_cluster_shutdown_signal(context: *anyopaque) void {
                    const self: *Cluster = @ptrCast(@alignCast(context));
                    self.request_shutdown();
                    // Disarm this watcher so the first worker's loop can drain.
                    if (self.signal_watcher) |*watcher| watcher.stop();
                }

                fn worker_main(self: *Cluster, index: usize) void {
                    pin_worker(self, index);
                    self.workers[index].run() catch |err| {
                        self.group.record_failure(index, .run, err);
                        self.worker_failed.store(true, .release);
                        // `run` returns the error; the log is diagnostic so a
                        // supervised caller can own alerting.
                        log.warn("worker {d} stopped with error: {s}", .{
                            index,
                            @errorName(err),
                        });
                        self.request_shutdown();
                    };
                }

                /// Pins one worker to its core; failure keeps startup graceful.
                fn pin_worker(self: *Cluster, index: usize) void {
                    if (!self.startup_options.cpu_affinity) return;
                    const cpu = self.cores.cpu(index) orelse return;
                    core_affinity.pin_current_thread(cpu) catch |err| {
                        // Restricted cpusets and affinity-less platforms are
                        // expected; only the first worker reports them.
                        if (index == 0) {
                            log.debug("worker affinity unavailable: {}", .{err});
                        }
                    };
                }
            };
        }

        fn listen_reuse_port(self: *Self, address: []const u8, port: u16) !void {
            return self.listen_all_options(
                &.{.{ .address = address, .port = port }},
                true,
            );
        }

        fn attach_cluster_inbox(self: *Self, inbox: *ClusterInbox) !void {
            if (self.cluster_inbox != null) return error.ClusterAlreadyAttached;
            self.cluster_wakeup = try xev.Async.init();
            self.cluster_inbox = inbox;
        }

        fn arm_cluster_wakeup(self: *Self) void {
            if (self.cluster_wakeup_active) return;
            if (self.cluster_wakeup == null) return;
            self.cluster_wakeup_active = true;
            self.cluster_wakeup.?.wait(
                self.loop.get_xev_loop(),
                &self.cluster_completion,
                Self,
                self,
                on_cluster_wakeup,
            );
        }

        fn notify_cluster(self: *Self) bool {
            const wakeup = if (self.cluster_wakeup) |*value| value else return false;
            wakeup.notify() catch return false;
            return true;
        }

        fn notify_cluster_delivery(self: *Self) bool {
            // A stopping loop disarms instead of draining its inbox, so a
            // queued message is not delivered and the wakeup is not counted.
            if (self.cluster_stop_requested.load(.acquire)) return false;
            return self.notify_cluster();
        }

        fn on_cluster_wakeup(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch {
                self.cluster_wakeup_active = false;
                return .disarm;
            };
            if (self.cluster_stop_requested.load(.acquire)) {
                self.cluster_wakeup_active = false;
                self.begin_shutdown();
                return .disarm;
            }

            // Non-cluster apps keep the wakeup armed: it is their only
            // request_shutdown delivery path.
            const inbox = self.cluster_inbox orelse return .rearm;
            while (inbox.pop_scratch()) |message| {
                _ = self.pubsub.publish(message.topic, message.payload, message.is_text);
            }
            return .rearm;
        }

        /// Serves the hidden Prometheus endpoint from a fixed stack buffer.
        ///
        /// The formatter writes straight into the buffer and the response
        /// engine copies it to the transport, so metric serving performs no
        /// heap allocation at all.
        fn serve_metrics(context: *anyopaque, _: *Request, response: *Response) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const registry = self.metrics_registry orelse {
                response.end_best_effort("404 Not Found", "");
                return;
            };

            var histogram: ?ebpf_module.Histogram = null;
            if (self.ebpf_map_fd >= 0) {
                if (ebpf_module.read_latency_histogram(self.ebpf_map_fd)) |observed| {
                    histogram = observed;
                } else |_| {
                    // A transient kernel read still leaves the counters usable.
                }
            }
            const buckets: ?[]const u64 = if (histogram) |observed|
                observed.buckets[0..]
            else
                null;

            var buffer: [4096]u8 = undefined;
            const body = registry.write_prometheus(buckets, &buffer) catch {
                response.end_best_effort("500 Internal Server Error", "metrics buffer exhausted");
                return;
            };
            response.end_with_headers_best_effort(
                "200 OK",
                "Content-Type: text/plain; version=0.0.4\r\n",
                body,
            );
        }

        fn serve_openapi(context: *anyopaque, _: *Request, response: *Response) void {
            const router: *const radix.Router = @ptrCast(@alignCast(context));
            // The document shares the buffer with write_openapi's route snapshot.
            var buffer: [64 * 1024]u8 = undefined;
            const document = router.write_openapi(&buffer, .{}) catch {
                response.end_best_effort(
                    "500 Internal Server Error",
                    "OpenAPI document exceeds capacity",
                );
                return;
            };
            response.end_with_headers_best_effort(
                "200 OK",
                "Content-Type: application/json\r\n",
                document,
            );
        }
    };
}

/// One connection's borrowed slices of the shared extra-header pointer region.
pub const HeaderExtras = struct {
    /// Header-name slices beyond the inline `Request` arrays.
    names: [][]const u8,
    /// Header-value slices matching `names`.
    values: [][]const u8,
};

/// One connection's borrowed slices of the shared extra route-capture pointer
/// region; empty when the configuration matches inline capacity.
pub const RouteParamExtras = struct {
    /// Route-parameter-name slices beyond the inline `Request` arrays.
    names: [][]const u8,
    /// Route-parameter-value slices matching `names`.
    values: [][]const u8,
};

/// Separate borrowed scratch slices for inbound and outbound compression.
pub const CompressionBuffers = struct {
    /// Scratch storage for compressed client messages and decode tails.
    incoming: []u8,
    /// Scratch storage for compressed server messages.
    outgoing: []u8,
};

/// Selects one connection's disjoint compression buffers from caller storage.
pub fn compression_buffers(
    storage: []u8,
    direction_capacity: usize,
    connection_index: usize,
) ?CompressionBuffers {
    if (direction_capacity == 0) return null;
    const stride = std.math.mul(usize, direction_capacity, 2) catch return null;
    const start = std.math.mul(usize, connection_index, stride) catch return null;
    const incoming_end = std.math.add(usize, start, direction_capacity) catch return null;
    const outgoing_end = std.math.add(usize, incoming_end, direction_capacity) catch return null;
    if (outgoing_end > storage.len) return null;

    return .{
        .incoming = storage[start..incoming_end],
        .outgoing = storage[incoming_end..outgoing_end],
    };
}

/// bpffs path where the latency histogram map is pinned by the loader.
const ebpf_map_path = "/sys/fs/bpf/uwz_latency";

fn close_socket_now(socket: xev.TCP) void {
    core_tcp.close_socket(xev.tcp_fd(socket));
}
