//! High-level server capacity configuration and contiguous slab planning.
//!
//! `ServerConfig` replaces byte-level capacity arithmetic with named limits.
//! `SlabLayout` translates one config into the exact per-connection strides
//! and the single contiguous region that the application allocates at startup.
//! Nothing in this module allocates; `carve` only partitions caller storage.

const std = @import("std");
const core_tcp = @import("../core/tcp.zig");
const http_parser = @import("../http/parser.zig");
const request_module = @import("../http/request.zig");
const quic_stream = @import("../quic/stream.zig");
const ws_deflate = @import("../ws/deflate.zig");
const rejection = @import("../http/rejection.zig");
const xdp_transport = @import("../xdp/transport.zig");
const datagram_ring = @import("../quic/datagram_ring.zig");
const metrics_module = @import("../observability/metrics.zig");
const file_watch = @import("../observability/file_watch.zig");
const radix = @import("radix.zig");
const radix_pattern = @import("radix_pattern.zig");

/// Request buffer stride alignment; keeps every body start SIMD-friendly.
pub const request_buffer_alignment = 16;
/// Write queue alignment; keeps each bounded ring on a cache line.
pub const write_queue_alignment = 64;
/// WebSocket message storage alignment.
pub const message_storage_alignment = 16;
/// Every carved region starts on at least a cache line.
pub const slab_alignment = @max(64, @alignOf(core_tcp.TcpConnection));

/// HTTP/2 session type instantiated with the TCP connection stream capacity.
const Http2Session = core_tcp.Http2Session;

/// Transport backend selected by a configuration.
///
/// `kernel_bypass` is a request, not a guarantee: `xdp_transport.resolve_mode`
/// drops it on non-Linux targets and the runtime probe falls back to the
/// standard stack when the kernel or process privileges refuse AF_XDP.
pub const TransportMode = xdp_transport.Mode;

/// Failures raised while validating a configuration or planning its slab.
pub const Error = error{
    InvalidConnectionCapacity,
    InvalidWebSocketMessageCapacity,
    InvalidWriteQueueCapacity,
    InvalidBodyCapacity,
    InvalidRequestLineCapacity,
    InvalidHeaderCapacity,
    InvalidHttp2Capacity,
    InvalidHttp3Capacity,
    InvalidRouterCapacity,
    InvalidIdleTimeout,
    InvalidDatagramCapacity,
    InvalidTransportConfiguration,
    InvalidMetricsPath,
    InvalidWatchConfiguration,
    WatchRequiresDevLog,
    MisalignedSlab,
    SlabSizeOverflow,
    SlabTooSmall,
};

/// Upper bound on decoded HTTP/3 response header fields.
///
/// The QUIC stream stacks one transmit descriptor per configured field, so the
/// count is capped to keep response framing off the guard page.
pub const h3_response_header_count_limit = 4096;

/// Human-readable server capacities translated once into one startup slab.
///
/// Capacities are compile-time by design: they determine the type of the
/// generated application. Use `with` to derive a tweaked config and construct
/// the server through `router/builder.zig`.
pub const ServerConfig = struct {
    /// Maximum simultaneous connections held in the contiguous pool slab.
    max_connections: usize = 1024,
    /// Maximum complete WebSocket message stored per connection.
    max_ws_message_size: usize = 16 * 1024,
    /// Bounded pending-output bytes per connection.
    write_queue_size: usize = 64 * 1024,
    /// Largest accepted HTTP/1.1 request body.
    max_body_size: usize = http_parser.default_max_body_size,
    /// Largest accepted HTTP/1.1 request line in bytes.
    ///
    /// The request buffer reserves this many bytes ahead of the header block.
    max_request_line_size: usize = http_parser.max_request_line_size,
    /// Largest accepted HTTP/1.1 header block in bytes.
    ///
    /// The request buffer reserves this many bytes ahead of the body; headers
    /// beyond the inline `Request` arrays also need `max_header_count` slots.
    /// HTTP/2 and HTTP/3 request-header storage share this value. HTTP/3
    /// activation requires it to fit the 16-bit lsxpack field length.
    max_header_size: usize = http_parser.max_header_size,
    /// Maximum headers accepted on one request, including overflow storage.
    ///
    /// Values below `Request.max_headers` are rejected because the inline
    /// arrays cannot shrink; larger values carve one name/value pair per extra
    /// header into the per-connection slab region.
    max_header_count: usize = request_module.max_headers,
    /// Maximum radix routing nodes retained for the route table.
    ///
    /// One node stores one path segment; shared prefixes count once. Values
    /// above `std.math.maxInt(u16)` are rejected because node indexes are u16.
    max_route_nodes: usize = radix.default_max_nodes,
    /// Maximum parameterized route patterns retained for matching.
    max_pattern_routes: usize = radix.default_max_pattern_routes,
    /// Maximum ordered global middleware callbacks.
    max_middleware: usize = radix.default_max_middleware,
    /// Maximum accepted route path length in bytes.
    ///
    /// Values above `std.math.maxInt(u16)` are rejected because segment
    /// lengths are u16.
    max_route_path_size: usize = radix_pattern.max_route_path_size,
    /// Maximum route captures accepted on one request, including overflow.
    ///
    /// Values below `Request.max_route_params` are rejected because the inline
    /// arrays cannot shrink; larger values carve one name/value pointer pair
    /// per extra capture into the per-connection slab region.
    max_route_params: usize = request_module.max_route_params,
    /// Bytes reserved for the route paths retained for introspection.
    ///
    /// Must hold at least one `max_route_path_size` path.
    max_route_registry_size: usize = 64 * 1024,
    /// Largest accepted HTTP/2 header block in bytes per request.
    max_h2_header_block_size: usize = 16 * 1024,
    /// Largest accepted HTTP/2 request body in bytes per stream.
    max_h2_body_size: usize = 16 * 1024,
    /// Largest encoded HTTP/2 response header block in bytes per response.
    ///
    /// The HPACK encoder fails closed when a response block exceeds it.
    max_h2_response_header_size: usize = 4 * 1024,
    /// Maximum HTTP/2 response header fields per response.
    ///
    /// Includes the status field and the generated `content-length` field.
    max_h2_response_header_count: usize = 32,
    /// Largest accepted HTTP/3 request body in bytes per stream.
    ///
    /// The QUIC engine reserves this much body storage per configured client
    /// outside the startup slab.
    max_h3_body_size: usize = 16 * 1024,
    /// Largest encoded HTTP/3 response header storage in bytes per response.
    ///
    /// The QUIC stream fails closed when a response head exceeds it; values
    /// above 65535 are rejected because field offsets and lengths are u16.
    max_h3_response_header_size: usize = 4096,
    /// Maximum decoded HTTP/3 response header fields per response.
    ///
    /// Capped at `h3_response_header_count_limit`; the QUIC stream stacks one
    /// transmit descriptor per field.
    max_h3_response_header_count: usize = 64,
    /// Inactivity timeout in milliseconds; zero disables the sweeper.
    idle_timeout_ms: u64 = 120_000,
    /// Reserves per-connection RFC 7692 scratch inside the startup slab.
    compression: bool = false,
    /// Reserves one per-worker gzip codec for `Response.end_gzip`.
    http_compression: bool = false,
    /// Requested transport backend; see `TransportMode`.
    transport: TransportMode = .standard,
    /// Largest single WebTransport datagram payload; zero disables datagrams.
    max_datagram_size: usize = 0,
    /// Pending datagram slots reserved per connection; zero disables datagrams.
    datagram_slots: usize = 0,
    /// AF_XDP UMEM chunk size in bytes; must be a power of two.
    xdp_frame_size: usize = 2048,
    /// AF_XDP UMEM frame count; must be a power of two.
    xdp_frame_count: usize = 1024,
    /// Serves the hidden Prometheus endpoint when enabled.
    observability: bool = false,
    /// Path of the observability endpoint; retained for the app lifetime.
    metrics_path: []const u8 = "/metrics",
    /// Writes the startup wordmark, ready summary, and colored event lines.
    ///
    /// Defaults on. The default stderr sink stays quiet when stderr is not a
    /// terminal, so redirected runs are not slowed; `App.set_dev_log_file`
    /// binds an output that always records.
    enable_dev_log: bool = true,
    /// Directories watched recursively for the development log; empty is off.
    ///
    /// Nonempty paths require `enable_dev_log`. Linux watches them through
    /// inotify; every other target scans them on a loop timer. Paths are
    /// borrowed for the application lifetime, like `metrics_path`.
    watch_paths: []const []const u8 = &.{},

    /// Optional per-field replacements accepted by `with`.
    ///
    /// A null field leaves the matching `ServerConfig` field unchanged.
    pub const Overrides = struct {
        /// Replaces `max_connections` when non-null.
        max_connections: ?usize = null,
        /// Replaces `max_ws_message_size` when non-null.
        max_ws_message_size: ?usize = null,
        /// Replaces `write_queue_size` when non-null.
        write_queue_size: ?usize = null,
        /// Replaces `max_body_size` when non-null.
        max_body_size: ?usize = null,
        /// Replaces `max_request_line_size` when non-null.
        max_request_line_size: ?usize = null,
        /// Replaces `max_header_size` when non-null.
        max_header_size: ?usize = null,
        /// Replaces `max_header_count` when non-null.
        max_header_count: ?usize = null,
        /// Replaces `max_route_nodes` when non-null.
        max_route_nodes: ?usize = null,
        /// Replaces `max_pattern_routes` when non-null.
        max_pattern_routes: ?usize = null,
        /// Replaces `max_middleware` when non-null.
        max_middleware: ?usize = null,
        /// Replaces `max_route_path_size` when non-null.
        max_route_path_size: ?usize = null,
        /// Replaces `max_route_params` when non-null.
        max_route_params: ?usize = null,
        /// Replaces `max_route_registry_size` when non-null.
        max_route_registry_size: ?usize = null,
        /// Replaces `max_h2_header_block_size` when non-null.
        max_h2_header_block_size: ?usize = null,
        /// Replaces `max_h2_body_size` when non-null.
        max_h2_body_size: ?usize = null,
        /// Replaces `max_h2_response_header_size` when non-null.
        max_h2_response_header_size: ?usize = null,
        /// Replaces `max_h2_response_header_count` when non-null.
        max_h2_response_header_count: ?usize = null,
        /// Replaces `max_h3_body_size` when non-null.
        max_h3_body_size: ?usize = null,
        /// Replaces `max_h3_response_header_size` when non-null.
        max_h3_response_header_size: ?usize = null,
        /// Replaces `max_h3_response_header_count` when non-null.
        max_h3_response_header_count: ?usize = null,
        /// Replaces `idle_timeout_ms` when non-null.
        idle_timeout_ms: ?u64 = null,
        /// Replaces `compression` when non-null.
        compression: ?bool = null,
        /// Replaces `http_compression` when non-null.
        http_compression: ?bool = null,
        /// Replaces `transport` when non-null.
        transport: ?TransportMode = null,
        /// Replaces `max_datagram_size` when non-null.
        max_datagram_size: ?usize = null,
        /// Replaces `datagram_slots` when non-null.
        datagram_slots: ?usize = null,
        /// Replaces `xdp_frame_size` when non-null.
        xdp_frame_size: ?usize = null,
        /// Replaces `xdp_frame_count` when non-null.
        xdp_frame_count: ?usize = null,
        /// Replaces `observability` when non-null.
        observability: ?bool = null,
        /// Replaces `metrics_path` when non-null.
        metrics_path: ?[]const u8 = null,
        /// Replaces `enable_dev_log` when non-null.
        enable_dev_log: ?bool = null,
        /// Replaces `watch_paths` when non-null.
        watch_paths: ?[]const []const u8 = null,
    };

    /// Returns a copy with every non-null override field replaced.
    pub fn with(self: ServerConfig, overrides: Overrides) ServerConfig {
        var result = self;
        if (overrides.max_connections) |value| result.max_connections = value;
        if (overrides.max_ws_message_size) |value| result.max_ws_message_size = value;
        if (overrides.write_queue_size) |value| result.write_queue_size = value;
        if (overrides.max_body_size) |value| result.max_body_size = value;
        if (overrides.max_request_line_size) |value| result.max_request_line_size = value;
        if (overrides.max_header_size) |value| result.max_header_size = value;
        if (overrides.max_header_count) |value| result.max_header_count = value;
        if (overrides.max_route_nodes) |value| result.max_route_nodes = value;
        if (overrides.max_pattern_routes) |value| result.max_pattern_routes = value;
        if (overrides.max_middleware) |value| result.max_middleware = value;
        if (overrides.max_route_path_size) |value| result.max_route_path_size = value;
        if (overrides.max_route_params) |value| result.max_route_params = value;
        if (overrides.max_route_registry_size) |value| result.max_route_registry_size = value;
        if (overrides.max_h2_header_block_size) |value| result.max_h2_header_block_size = value;
        if (overrides.max_h2_body_size) |value| result.max_h2_body_size = value;
        if (overrides.max_h2_response_header_size) |value| result.max_h2_response_header_size = value;
        if (overrides.max_h2_response_header_count) |value| result.max_h2_response_header_count = value;
        if (overrides.max_h3_body_size) |value| result.max_h3_body_size = value;
        if (overrides.max_h3_response_header_size) |value| result.max_h3_response_header_size = value;
        if (overrides.max_h3_response_header_count) |value| result.max_h3_response_header_count = value;
        if (overrides.idle_timeout_ms) |value| result.idle_timeout_ms = value;
        if (overrides.compression) |value| result.compression = value;
        if (overrides.http_compression) |value| result.http_compression = value;
        if (overrides.transport) |value| result.transport = value;
        if (overrides.max_datagram_size) |value| result.max_datagram_size = value;
        if (overrides.datagram_slots) |value| result.datagram_slots = value;
        if (overrides.xdp_frame_size) |value| result.xdp_frame_size = value;
        if (overrides.xdp_frame_count) |value| result.xdp_frame_count = value;
        if (overrides.observability) |value| result.observability = value;
        if (overrides.metrics_path) |value| result.metrics_path = value;
        if (overrides.enable_dev_log) |value| result.enable_dev_log = value;
        if (overrides.watch_paths) |value| result.watch_paths = value;
        return result;
    }

    /// Rejects configurations that cannot produce a usable slab.
    pub fn validate(self: ServerConfig) Error!void {
        // Builder specialization evaluates the whole plan at compile time; the
        // default quota is too small for the combined router and H2 planners.
        @setEvalBranchQuota(10_000);
        if (self.max_connections == 0) return error.InvalidConnectionCapacity;
        if (self.max_ws_message_size == 0) return error.InvalidWebSocketMessageCapacity;
        if (self.write_queue_size == 0) return error.InvalidWriteQueueCapacity;
        if (self.max_body_size == 0) return error.InvalidBodyCapacity;
        if (self.max_request_line_size == 0) return error.InvalidRequestLineCapacity;
        if (self.max_header_size == 0) return error.InvalidHeaderCapacity;
        if (self.max_header_count < request_module.max_headers) return error.InvalidHeaderCapacity;
        if (self.max_route_params < request_module.max_route_params) {
            return error.InvalidRouterCapacity;
        }
        // Reject header and route-param counts whose pointer storage overflows.
        _ = try self.extra_header_stride();
        _ = try self.extra_route_param_stride();
        // Reject H3 engine capacities the QUIC storage plan cannot carry.
        try self.validate_h3();
        // Reject H2 session capacities the storage planner cannot lay out.
        _ = try self.h2_session_stride();
        // Reject router capacities the radix router cannot represent.
        try self.validate_router();
        if (self.idle_timeout_ms > std.math.maxInt(i64)) return error.InvalidIdleTimeout;
        try self.validate_datagrams();
        try self.validate_transport();
        try self.validate_watch();
    }

    fn validate_router(self: ServerConfig) Error!void {
        _ = try self.router_storage_bytes();
    }

    fn validate_datagrams(self: ServerConfig) Error!void {
        if (self.max_datagram_size == 0) {
            if (self.datagram_slots != 0) return error.InvalidDatagramCapacity;
            return;
        }
        if (self.datagram_slots == 0) return error.InvalidDatagramCapacity;
        // The ring stores lengths as u32 and addresses slots with u32 cursors.
        if (self.max_datagram_size > std.math.maxInt(u32)) return error.InvalidDatagramCapacity;
        if (self.datagram_slots > std.math.maxInt(u32)) return error.InvalidDatagramCapacity;
    }

    fn validate_transport(self: ServerConfig) Error!void {
        if (self.transport == .kernel_bypass) {
            if (!std.math.isPowerOfTwo(self.xdp_frame_size)) {
                return error.InvalidTransportConfiguration;
            }
            if (self.xdp_frame_size < 1024 or self.xdp_frame_size > 64 * 1024) {
                return error.InvalidTransportConfiguration;
            }
            if (!std.math.isPowerOfTwo(self.xdp_frame_count) or self.xdp_frame_count == 0) {
                return error.InvalidTransportConfiguration;
            }
            if (self.xdp_frame_count > xdp_transport.max_frames) {
                return error.InvalidTransportConfiguration;
            }
        }
        if (self.observability) {
            if (self.metrics_path.len == 0 or self.metrics_path[0] != '/') {
                return error.InvalidMetricsPath;
            }
        }
    }

    fn validate_watch(self: ServerConfig) Error!void {
        if (self.watch_paths.len == 0) return;
        if (!self.enable_dev_log) return error.WatchRequiresDevLog;
        if (self.watch_paths.len > file_watch.max_roots) {
            return error.InvalidWatchConfiguration;
        }
        for (self.watch_paths) |path| {
            if (path.len == 0 or path.len + 1 > file_watch.max_path_bytes) {
                return error.InvalidWatchConfiguration;
            }
        }
    }

    /// Bytes reserved per connection for all pending datagrams.
    pub fn datagram_stride(self: ServerConfig) Error!usize {
        if (self.max_datagram_size == 0) return 0;
        return std.math.mul(usize, self.datagram_slots, self.max_datagram_size) catch
            return error.SlabSizeOverflow;
    }

    /// AF_XDP UMEM bytes; zero when the standard transport is selected.
    pub fn xdp_umem_bytes(self: ServerConfig) Error!usize {
        if (self.transport != .kernel_bypass) return 0;
        return std.math.mul(usize, self.xdp_frame_count, self.xdp_frame_size) catch
            return error.SlabSizeOverflow;
    }

    /// Base alignment the owning allocation must satisfy for this configuration.
    ///
    /// AF_XDP registers the slab region itself as UMEM, and the kernel rejects
    /// any registration that is not page aligned.
    pub fn required_alignment(self: ServerConfig) usize {
        if (self.transport == .kernel_bypass) return std.heap.page_size_min;
        return slab_alignment;
    }

    /// Bytes reserved per connection for one HTTP/1.1 request.
    pub fn request_buffer_stride(self: ServerConfig) Error!usize {
        if (self.max_body_size == 0) return error.InvalidBodyCapacity;

        const fixed = std.math.add(
            usize,
            self.max_request_line_size,
            self.max_header_size,
        ) catch return error.SlabSizeOverflow;
        const fixed_with_slack = std.math.add(usize, fixed, 1024) catch
            return error.SlabSizeOverflow;
        const total = std.math.add(usize, self.max_body_size, fixed_with_slack) catch
            return error.SlabSizeOverflow;
        return align_checked(total, request_buffer_alignment);
    }

    /// Header slots reserved per connection beyond the inline `Request` arrays.
    pub fn extra_header_capacity(self: ServerConfig) Error!usize {
        if (self.max_header_count < request_module.max_headers) {
            return error.InvalidHeaderCapacity;
        }
        return self.max_header_count - request_module.max_headers;
    }

    /// Bytes reserved per connection for the extra header name/value pointers.
    ///
    /// Zero when `max_header_count` matches the inline `Request` capacity.
    pub fn extra_header_stride(self: ServerConfig) Error!usize {
        const capacity = try self.extra_header_capacity();
        if (capacity == 0) return 0;
        const pointers = std.math.mul(usize, capacity, 2) catch
            return error.SlabSizeOverflow;
        const bytes = std.math.mul(usize, pointers, @sizeOf([]const u8)) catch
            return error.SlabSizeOverflow;
        return align_checked(bytes, request_buffer_alignment);
    }

    /// Route-capture slots reserved per connection beyond the inline arrays.
    pub fn extra_route_param_capacity(self: ServerConfig) Error!usize {
        if (self.max_route_params < request_module.max_route_params) {
            return error.InvalidRouterCapacity;
        }
        return self.max_route_params - request_module.max_route_params;
    }

    /// Bytes reserved per connection for the extra route-capture pointers.
    ///
    /// Zero when `max_route_params` matches the inline `Request` capacity.
    pub fn extra_route_param_stride(self: ServerConfig) Error!usize {
        const capacity = try self.extra_route_param_capacity();
        if (capacity == 0) return 0;
        const pointers = std.math.mul(usize, capacity, 2) catch
            return error.SlabSizeOverflow;
        const bytes = std.math.mul(usize, pointers, @sizeOf([]const u8)) catch
            return error.SlabSizeOverflow;
        return align_checked(bytes, @alignOf([]const u8));
    }

    /// Bytes reserved per connection for paired RFC 7692 scratch regions.
    pub fn compression_stride(self: ServerConfig) Error!usize {
        if (self.max_ws_message_size == 0) return error.InvalidWebSocketMessageCapacity;

        const per_direction = ws_deflate.worst_case_scratch_bound(self.max_ws_message_size) catch
            return error.SlabSizeOverflow;
        const both = std.math.mul(usize, per_direction, 2) catch
            return error.SlabSizeOverflow;
        return align_checked(both, request_buffer_alignment);
    }

    /// Total contiguous slab bytes required by this configuration.
    pub fn slab_bytes(self: ServerConfig) Error!usize {
        return (try layout_offsets(self)).total_bytes;
    }

    /// Capacity set projected into the radix router's configuration.
    pub fn router_capacities(self: ServerConfig) radix.Capacities {
        return .{
            .max_nodes = self.max_route_nodes,
            .max_pattern_routes = self.max_pattern_routes,
            .max_middleware = self.max_middleware,
            .max_route_path_size = self.max_route_path_size,
            .max_route_params = self.max_route_params,
            .registry_storage_size = self.max_route_registry_size,
        };
    }

    /// Bytes the router-storage region needs for this configuration.
    pub fn router_storage_bytes(self: ServerConfig) Error!usize {
        return self.router_capacities().storage_bytes() catch error.InvalidRouterCapacity;
    }

    /// Capacity set projected into the HTTP/2 session's storage planner.
    ///
    /// Request header bytes and decoded field counts follow the HTTP/1 policy
    /// so one connection cannot accept a larger field list over HTTP/2.
    pub fn h2_capacities(self: ServerConfig) Http2Session.Capacities {
        return .{
            .header_block_size = self.max_h2_header_block_size,
            .request_header_size = self.max_header_size,
            .body_size = self.max_h2_body_size,
            .response_header_size = self.max_h2_response_header_size,
            .response_header_count = self.max_h2_response_header_count,
            .decoded_header_count = self.max_header_count,
            .dynamic_table_size = Http2Session.default_capacities.dynamic_table_size,
        };
    }

    /// Bytes one connection's carved HTTP/2 session storage needs.
    pub fn h2_session_bytes(self: ServerConfig) Error!usize {
        return Http2Session.storage_bytes(self.h2_capacities()) catch
            error.InvalidHttp2Capacity;
    }

    /// Aligned per-connection stride of the HTTP/2 session storage region.
    pub fn h2_session_stride(self: ServerConfig) Error!usize {
        return align_checked(try self.h2_session_bytes(), Http2Session.storage_alignment);
    }

    /// Capacity set projected into the QUIC engine's per-stream storage.
    ///
    /// Request header bytes and the decoded field cap follow the HTTP/1 policy
    /// so one client cannot accept a larger field list over HTTP/3; request
    /// fields beyond the inline `Request` arrays use the extra pointer slots.
    /// Callers run `validate` first; an invalid header count projects to zero
    /// extra slots.
    pub fn h3_capacities(self: ServerConfig) quic_stream.Capacities {
        return .{
            .request_header_size = self.max_header_size,
            .request_body_size = self.max_h3_body_size,
            .response_header_size = self.max_h3_response_header_size,
            .response_header_count = self.max_h3_response_header_count,
            .decoded_header_count = self.max_header_count,
            .header_extra_capacity = self.max_header_count -| request_module.max_headers,
        };
    }

    /// Bytes the QUIC engine allocates outside the startup slab for this config.
    ///
    /// The engine keeps its pools and per-stream slabs in page-allocated
    /// regions created at `listen_udp`; this total covers the large byte slabs
    /// and pointer arrays so the per-client cost is documented and checked.
    /// It mirrors the product bounds `quic_engine` enforces at comptime.
    pub fn h3_engine_bytes(self: ServerConfig) Error!usize {
        const capacities = self.h3_capacities();
        const connections = self.max_connections;

        // Two header-set slabs per connection; one request body, response
        // header, and response body slab; two pointer slices per extra slot.
        const header_slots = std.math.mul(usize, connections, 2) catch
            return error.SlabSizeOverflow;
        var total = std.math.mul(usize, header_slots, capacities.request_header_size) catch
            return error.SlabSizeOverflow;
        total = try h3_sum(total, try h3_product(connections, capacities.request_body_size));
        total = try h3_sum(total, try h3_product(connections, capacities.response_header_size));
        total = try h3_sum(total, try h3_product(connections, self.write_queue_size));

        const route_pointers = try h3_product(try self.extra_route_param_capacity(), 2);
        const route_bytes = try h3_product(route_pointers, @sizeOf([]const u8));
        total = try h3_sum(total, try h3_product(connections, route_bytes));

        const header_extra_pointers = try h3_product(capacities.header_extra_capacity, 2);
        const header_extra_bytes = try h3_product(header_extra_pointers, @sizeOf([]const u8));
        return h3_sum(total, try h3_product(connections, header_extra_bytes));
    }

    /// Rejects HTTP/3 capacities the QUIC engine cannot represent or carry.
    fn validate_h3(self: ServerConfig) Error!void {
        if (self.max_h3_body_size == 0) return error.InvalidHttp3Capacity;
        if (self.max_h3_response_header_size == 0) return error.InvalidHttp3Capacity;
        if (self.max_h3_response_header_count == 0) return error.InvalidHttp3Capacity;
        if (self.max_h3_response_header_count > h3_response_header_count_limit) {
            return error.InvalidHttp3Capacity;
        }
        // Response field offsets and lengths are u16 in the lsquic header API.
        if (self.max_h3_response_header_size > std.math.maxInt(u16)) {
            return error.InvalidHttp3Capacity;
        }
        // Request header bytes and the QUIC receive credit are u32. The tighter
        // lsxpack u16 field-length bound is enforced only when HTTP/3 starts.
        if (self.max_header_size > std.math.maxInt(u32)) return error.InvalidHttp3Capacity;
        if (self.max_h3_body_size > std.math.maxInt(u32) - self.max_header_size) {
            return error.InvalidHttp3Capacity;
        }
        _ = try self.h3_engine_bytes();
    }

    /// Fixed rejection policy rendered into transport error responses.
    pub fn rejection_policy(self: ServerConfig) rejection.RejectionPolicy {
        return .{
            .max_body_size = self.max_body_size,
            .max_header_size = self.max_header_size,
        };
    }

    /// Named presets for common deployment shapes.
    ///
    /// Every preset is a plain `ServerConfig`, so any field remains overridable
    /// through `Server.builder(...)` and its `with_*` methods. The per-connection footprint is dominated by
    /// the HTTP/2 request slabs embedded in each connection, so these presets
    /// choose conservative connection counts and spend their bytes on the
    /// capacity that each workload actually exercises.
    pub const Preset = struct {
        /// Small JSON payloads, many routing nodes, moderate connection count.
        pub const microservice: ServerConfig = .{
            .max_connections = 256,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 16 * 1024,
            .max_body_size = 64 * 1024,
            .idle_timeout_ms = 30_000,
        };
        /// Maximum connection count with pre-reserved compression scratch.
        pub const websocket_chat: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 32 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 4 * 1024,
            .idle_timeout_ms = 120_000,
            .compression = true,
        };
        /// Large contiguous response rings, few concurrent connections.
        pub const file_server: ServerConfig = .{
            .max_connections = 128,
            .max_ws_message_size = 4 * 1024,
            .write_queue_size = 512 * 1024,
            .max_body_size = 8 * 1024,
            .idle_timeout_ms = 300_000,
        };
        /// AF_XDP kernel bypass with a page-aligned UMEM carved from the slab.
        ///
        /// The bypass is opportunistic: platforms without AF_XDP and processes
        /// without the required privileges transparently use the standard path.
        pub const kernel_bypass: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 16 * 1024,
            .idle_timeout_ms = 60_000,
            .transport = .kernel_bypass,
            .observability = true,
        };
        /// Unreliable WebTransport datagrams with one SoA ring per connection.
        pub const webtransport_realtime: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 4 * 1024,
            .idle_timeout_ms = 60_000,
            .max_datagram_size = 1200,
            .datagram_slots = 64,
            .observability = true,
        };
    };
};

/// Defaults used by `App` and the builder entry point.
pub const default_config: ServerConfig = .{};

/// Field offsets of the single contiguous startup slab.
///
/// Both `required_bytes` and `carve` derive from one computation so sizing and
/// partitioning cannot drift apart.
const LayoutOffsets = struct {
    pool_start: usize,
    pool_end: usize,
    freelist_start: usize,
    freelist_end: usize,
    request_start: usize,
    request_end: usize,
    header_extras_start: usize,
    header_extras_end: usize,
    route_param_extras_start: usize,
    route_param_extras_end: usize,
    h2_session_start: usize,
    h2_session_end: usize,
    write_start: usize,
    write_end: usize,
    message_start: usize,
    message_end: usize,
    compression_start: usize,
    compression_end: usize,
    datagram_session_start: usize,
    datagram_session_end: usize,
    datagram_sequence_start: usize,
    datagram_sequence_end: usize,
    datagram_length_start: usize,
    datagram_length_end: usize,
    datagram_ring_start: usize,
    datagram_ring_end: usize,
    datagram_payload_start: usize,
    datagram_payload_end: usize,
    xdp_umem_start: usize,
    xdp_umem_end: usize,
    xdp_transport_start: usize,
    xdp_transport_end: usize,
    metrics_start: usize,
    metrics_end: usize,
    router_storage_start: usize,
    router_storage_end: usize,
    total_bytes: usize,
};

/// Views over one carved slab. Every slice borrows the slab storage.
pub const SlabLayout = struct {
    /// The whole startup block; the owner frees exactly this slice.
    slab: []u8,
    /// Contiguous connection state array (the hot SoA region).
    pool_storage: []core_tcp.TcpConnection,
    /// LIFO freelist indices paired with `pool_storage`.
    freelist: []usize,
    /// One HTTP/1.1 request buffer per connection, `request_buffer_stride` apart.
    request_buffers: []u8,
    /// Per-connection header name/value pointer storage beyond the inline
    /// `Request` arrays, `extra_header_stride` apart.
    header_extras: []u8,
    /// Per-connection route-capture pointer storage beyond the inline
    /// `Request` arrays, `extra_route_param_stride` apart.
    route_param_extras: []u8,
    /// Per-connection carved HTTP/2 session storage, `h2_session_stride` apart.
    h2_sessions: []u8,
    /// One bounded response ring per connection, `write_queue_size` apart.
    write_queues: []u8,
    /// One WebSocket message region per connection, `max_ws_message_size` apart.
    ws_messages: []u8,
    /// Optional paired DEFLATE scratch, zero-length when compression is off.
    compression_scratch: []u8,
    /// Per-connection datagram session ids, `datagram_slots` per connection.
    datagram_session_ids: []u64,
    /// Per-connection datagram sequence numbers.
    datagram_sequences: []u64,
    /// Per-connection datagram payload lengths.
    datagram_payload_lengths: []u32,
    /// One persistent ring cursor struct per connection.
    datagram_rings: []datagram_ring.DatagramRing,
    /// Per-connection fixed-stride datagram payload storage.
    datagram_payloads: []u8,
    /// Byte distance between consecutive connections' datagram payload slabs.
    datagram_stride: usize,
    /// AF_XDP UMEM region; zero-length unless kernel bypass is selected.
    xdp_umem: []align(std.heap.page_size_min) u8,
    /// Storage for the optional `xdp_transport.XdpTransport`; zero-length
    /// unless kernel bypass is selected. The consumer casts it after checking
    /// the configuration because the region may be empty.
    xdp_transport_bytes: []u8,
    /// Cache-line-aligned metrics registry; null unless observability is on.
    metrics_registry: ?*metrics_module.Registry,
    /// Router capacity storage carved exactly once per application.
    router_storage: []u8,
    /// Byte distance between consecutive request buffers.
    request_buffer_stride: usize,
    /// Byte distance between consecutive HTTP/2 session storage regions.
    h2_session_stride: usize,
    /// Byte distance between consecutive header-extras pointer regions.
    extra_header_stride: usize,
    /// Byte distance between consecutive route-capture pointer regions.
    extra_route_param_stride: usize,
    /// Byte distance between consecutive paired compression scratch regions.
    compression_stride: usize,
    /// Total bytes consumed inside `slab`.
    total_bytes: usize,
    /// Required base alignment of `slab`.
    alignment: usize,

    /// Partitions `slab` into typed views without allocating.
    pub fn carve(slab: []u8, config: ServerConfig) Error!SlabLayout {
        const offsets = try layout_offsets(config);
        if (slab.len < offsets.total_bytes) return error.SlabTooSmall;
        if (@intFromPtr(slab.ptr) % config.required_alignment() != 0) {
            return error.MisalignedSlab;
        }

        return .{
            .slab = slab[0..offsets.total_bytes],
            .pool_storage = std.mem.bytesAsSlice(
                core_tcp.TcpConnection,
                region_bytes(core_tcp.TcpConnection, slab, offsets.pool_start, offsets.pool_end),
            ),
            .freelist = std.mem.bytesAsSlice(
                usize,
                region_bytes(usize, slab, offsets.freelist_start, offsets.freelist_end),
            ),
            .request_buffers = slab[offsets.request_start..offsets.request_end],
            .header_extras = slab[offsets.header_extras_start..offsets.header_extras_end],
            .route_param_extras = slab[offsets.route_param_extras_start..offsets.route_param_extras_end],
            .h2_sessions = slab[offsets.h2_session_start..offsets.h2_session_end],
            .write_queues = slab[offsets.write_start..offsets.write_end],
            .ws_messages = slab[offsets.message_start..offsets.message_end],
            .compression_scratch = slab[offsets.compression_start..offsets.compression_end],
            .datagram_session_ids = std.mem.bytesAsSlice(
                u64,
                region_bytes(u64, slab, offsets.datagram_session_start, offsets.datagram_session_end),
            ),
            .datagram_sequences = std.mem.bytesAsSlice(
                u64,
                region_bytes(u64, slab, offsets.datagram_sequence_start, offsets.datagram_sequence_end),
            ),
            .datagram_payload_lengths = std.mem.bytesAsSlice(
                u32,
                region_bytes(u32, slab, offsets.datagram_length_start, offsets.datagram_length_end),
            ),
            .datagram_rings = if (config.max_datagram_size != 0)
                std.mem.bytesAsSlice(
                    datagram_ring.DatagramRing,
                    region_bytes(
                        datagram_ring.DatagramRing,
                        slab,
                        offsets.datagram_ring_start,
                        offsets.datagram_ring_end,
                    ),
                )
            else
                empty_datagram_rings(),
            .datagram_payloads = slab[offsets.datagram_payload_start..offsets.datagram_payload_end],
            .datagram_stride = try config.datagram_stride(),
            .xdp_umem = if (config.transport == .kernel_bypass)
                @alignCast(slab[offsets.xdp_umem_start..offsets.xdp_umem_end])
            else
                empty_page_region(),
            .xdp_transport_bytes = slab[offsets.xdp_transport_start..offsets.xdp_transport_end],
            .metrics_registry = if (config.observability)
                @ptrCast(@alignCast(slab[offsets.metrics_start..offsets.metrics_end].ptr))
            else
                null,
            .router_storage = slab[offsets.router_storage_start..offsets.router_storage_end],
            .request_buffer_stride = try config.request_buffer_stride(),
            .h2_session_stride = try config.h2_session_stride(),
            .extra_header_stride = try config.extra_header_stride(),
            .extra_route_param_stride = try config.extra_route_param_stride(),
            .compression_stride = if (config.compression) try config.compression_stride() else 0,
            .total_bytes = offsets.total_bytes,
            .alignment = config.required_alignment(),
        };
    }
};

/// Computes the single contiguous slab size for `config`.
pub fn required_bytes(config: ServerConfig) Error!usize {
    return (try layout_offsets(config)).total_bytes;
}

/// Partitions caller storage according to `config`.
pub fn carve(slab: []u8, config: ServerConfig) Error!SlabLayout {
    return SlabLayout.carve(slab, config);
}

fn layout_offsets(config: ServerConfig) Error!LayoutOffsets {
    try config.validate();

    const request_stride = try config.request_buffer_stride();
    const extra_header_stride = try config.extra_header_stride();
    const extra_route_param_stride = try config.extra_route_param_stride();
    const h2_session_stride = try config.h2_session_stride();
    const compression_stride = if (config.compression) try config.compression_stride() else 0;

    var offsets: LayoutOffsets = undefined;
    var cursor: usize = 0;

    // Hot connection state first so request dispatch stays on the same pages.
    cursor = try align_checked(cursor, @alignOf(core_tcp.TcpConnection));
    offsets.pool_start = cursor;
    cursor = try add_product(cursor, @sizeOf(core_tcp.TcpConnection), config.max_connections);
    offsets.pool_end = cursor;

    cursor = try align_checked(cursor, @alignOf(usize));
    offsets.freelist_start = cursor;
    cursor = try add_product(cursor, @sizeOf(usize), config.max_connections);
    offsets.freelist_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.request_start = cursor;
    cursor = try add_product(cursor, request_stride, config.max_connections);
    offsets.request_end = cursor;

    // Extra header pointers sit next to the request buffers that publish them;
    // route-capture pointers follow in the same region, before the write
    // queues, so a request's direct pointer storage stays on adjacent pages.
    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.header_extras_start = cursor;
    cursor = try add_product(cursor, extra_header_stride, config.max_connections);
    offsets.header_extras_end = cursor;

    cursor = try align_checked(cursor, @alignOf([]const u8));
    offsets.route_param_extras_start = cursor;
    cursor = try add_product(cursor, extra_route_param_stride, config.max_connections);
    offsets.route_param_extras_end = cursor;

    // HTTP/2 session storage is carved per connection; the stride is aligned so
    // each region can be re-tagged as `Http2Session.Storage` without slack.
    cursor = try align_checked(cursor, Http2Session.storage_alignment);
    offsets.h2_session_start = cursor;
    cursor = try add_product(cursor, h2_session_stride, config.max_connections);
    offsets.h2_session_end = cursor;

    cursor = try align_checked(cursor, write_queue_alignment);
    offsets.write_start = cursor;
    cursor = try add_product(cursor, config.write_queue_size, config.max_connections);
    offsets.write_end = cursor;

    cursor = try align_checked(cursor, message_storage_alignment);
    offsets.message_start = cursor;
    cursor = try add_product(cursor, config.max_ws_message_size, config.max_connections);
    offsets.message_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.compression_start = cursor;
    cursor = try add_product(cursor, compression_stride, config.max_connections);
    offsets.compression_end = cursor;

    // Datagram metadata stays in its own arrays so a queue drain touches only
    // the hot length/round-trip fields and never the payload pages.
    const datagram_stride = try config.datagram_stride();
    const datagram_slot_count = std.math.mul(
        usize,
        config.datagram_slots,
        config.max_connections,
    ) catch return error.SlabSizeOverflow;

    cursor = try align_checked(cursor, @alignOf(u64));
    offsets.datagram_session_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u64), datagram_slot_count);
    offsets.datagram_session_end = cursor;

    offsets.datagram_sequence_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u64), datagram_slot_count);
    offsets.datagram_sequence_end = cursor;

    cursor = try align_checked(cursor, @alignOf(u32));
    offsets.datagram_length_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u32), datagram_slot_count);
    offsets.datagram_length_end = cursor;

    // The cursors must outlive any single call, so the ring structs are carved
    // per connection instead of being rebuilt from the metadata arrays.
    cursor = try align_checked(cursor, @alignOf(datagram_ring.DatagramRing));
    offsets.datagram_ring_start = cursor;
    cursor = try add_product(
        cursor,
        @sizeOf(datagram_ring.DatagramRing),
        config.max_connections,
    );
    offsets.datagram_ring_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.datagram_payload_start = cursor;
    cursor = try add_product(cursor, datagram_stride, config.max_connections);
    offsets.datagram_payload_end = cursor;

    // UMEM is registered directly from the slab, so the bypass path pays for a
    // page-aligned region while the standard path carves nothing at all.
    if (config.transport == .kernel_bypass) {
        const umem_bytes = try config.xdp_umem_bytes();
        cursor = try align_checked(cursor, std.heap.page_size_min);
        offsets.xdp_umem_start = cursor;
        cursor = std.math.add(usize, cursor, umem_bytes) catch return error.SlabSizeOverflow;
        offsets.xdp_umem_end = cursor;

        cursor = try align_checked(cursor, @alignOf(xdp_transport.XdpTransport));
        offsets.xdp_transport_start = cursor;
        cursor = std.math.add(
            usize,
            cursor,
            @sizeOf(xdp_transport.XdpTransport),
        ) catch return error.SlabSizeOverflow;
        offsets.xdp_transport_end = cursor;
    } else {
        offsets.xdp_umem_start = cursor;
        offsets.xdp_umem_end = cursor;
        offsets.xdp_transport_start = cursor;
        offsets.xdp_transport_end = cursor;
    }

    // The registry is always carved with its cache-line alignment so the
    // owning App struct never has to embed a 64-byte-aligned value.
    cursor = try align_checked(cursor, @alignOf(metrics_module.Registry));
    offsets.metrics_start = cursor;
    if (config.observability) {
        cursor = std.math.add(
            usize,
            cursor,
            @sizeOf(metrics_module.Registry),
        ) catch return error.SlabSizeOverflow;
    }
    offsets.metrics_end = cursor;

    // Router storage is one per-application region, independent of the
    // per-connection strides above; it trails the slab so raising a route
    // capacity never shifts a connection's storage.
    cursor = try align_checked(cursor, radix.storage_alignment);
    offsets.router_storage_start = cursor;
    cursor = std.math.add(usize, cursor, try config.router_storage_bytes()) catch
        return error.SlabSizeOverflow;
    offsets.router_storage_end = cursor;

    offsets.total_bytes = cursor;
    return offsets;
}

/// Page-aligned empty region returned when the bypass layout is not carved.
pub fn empty_page_region() []align(std.heap.page_size_min) u8 {
    return empty_page_storage[0..];
}

/// Empty ring slice returned when datagrams are disabled.
pub fn empty_datagram_rings() []datagram_ring.DatagramRing {
    return empty_datagram_ring_storage[0..];
}

var empty_page_storage: [0]u8 align(std.heap.page_size_min) = .{};
var empty_datagram_ring_storage: [0]datagram_ring.DatagramRing = .{};

fn add_product(cursor: usize, element_size: usize, count: usize) Error!usize {
    const bytes = std.math.mul(usize, element_size, count) catch return error.SlabSizeOverflow;
    return std.math.add(usize, cursor, bytes) catch return error.SlabSizeOverflow;
}

/// Checked QUIC-engine product; overflow means the slab cannot be represented.
fn h3_product(count: usize, stride: usize) Error!usize {
    return std.math.mul(usize, count, stride) catch error.SlabSizeOverflow;
}

/// Checked QUIC-engine sum; overflow means the slab cannot be represented.
fn h3_sum(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SlabSizeOverflow;
}

/// Re-tags an aligned slab region; `layout_offsets` guarantees the alignment.
fn region_bytes(comptime T: type, slab: []u8, start: usize, end: usize) []align(@alignOf(T)) u8 {
    return @alignCast(slab[start..end]);
}

fn align_checked(value: usize, alignment: usize) Error!usize {
    if (value > std.math.maxInt(usize) - (alignment - 1)) return error.SlabSizeOverflow;
    return std.mem.alignForward(usize, value, alignment);
}
