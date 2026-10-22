const std = @import("std");
const c = @import("c");
const pool = @import("../core/pool.zig");
const Router = @import("../router/radix.zig").Router;
const api = @import("lsquic_api.zig");
const stream = @import("stream.zig");
const HeaderSet = stream.HeaderSet;

const log = std.log.scoped(.quic);

/// Reports that the build includes the lsquic-backed QUIC engine.
pub const available = true;

/// lsquic congestion controller identifier for BBRv1 (`es_cc_algo`).
const cc_algo_bbr: c_uint = 2;

/// One fixed-size outbound UDP packet buffer owned by the engine packet pool.
pub const PacketSlot = struct {
    bytes: [api.max_udp_payload_size]u8,
};

/// Returns a bounded QUIC server engine type.
///
/// `capacity` bounds concurrent connections and request streams;
/// `response_capacity` reserves response body bytes per stream during `init`;
/// `route_param_extra_capacity` reserves capture slots per stream beyond the
/// inline `Request` arrays (zero keeps every capture inline);
/// `stream_capacities` fixes every per-stream HTTP/3 storage region and field
/// cap. The engine allocates its pools and byte slabs once in `init`, and
/// `deinit` releases them; nothing on the datagram path allocates.
pub fn quic_engine(
    comptime capacity: usize,
    comptime response_capacity: usize,
    comptime route_param_extra_capacity: usize,
    comptime stream_capacities: stream.Capacities,
) type {
    if (capacity == 0) @compileError("QUIC capacity must be greater than zero");
    if (capacity > std.math.maxInt(c_uint)) @compileError("QUIC capacity exceeds lsquic limits");
    if (response_capacity == 0) @compileError("HTTP/3 response capacity must be greater than zero");
    if (stream_capacities.request_header_size == 0) {
        @compileError("HTTP/3 request header capacity must be greater than zero");
    }
    // `es_max_header_list_size` is a u32; a larger field list cannot be carried.
    if (stream_capacities.request_header_size > std.math.maxInt(c_uint)) {
        @compileError("HTTP/3 request header capacity exceeds lsquic limits");
    }
    if (stream_capacities.request_body_size == 0) {
        @compileError("HTTP/3 request body capacity must be greater than zero");
    }
    if (stream_capacities.response_header_size == 0 or
        stream_capacities.response_header_size > std.math.maxInt(u16))
    {
        @compileError("HTTP/3 response header capacity must fit u16 offsets");
    }
    if (stream_capacities.response_header_count == 0) {
        @compileError("HTTP/3 response header count must be greater than zero");
    }
    if (stream_capacities.decoded_header_count == 0) {
        @compileError("HTTP/3 decoded header count must be greater than zero");
    }
    if (capacity > std.math.maxInt(usize) / 4) @compileError("QUIC packet capacity overflows usize");
    if (capacity > std.math.maxInt(usize) / 2) @compileError("HTTP/3 header slot count overflows usize");
    if (route_param_extra_capacity > std.math.maxInt(usize) / 2) {
        @compileError("HTTP/3 route parameter capacity overflows usize");
    }
    const route_param_pointer_count = route_param_extra_capacity * 2;
    if (route_param_pointer_count != 0 and
        capacity > std.math.maxInt(usize) / route_param_pointer_count)
    {
        @compileError("HTTP/3 route parameter storage size overflows usize");
    }
    const route_param_slot_count = capacity * route_param_pointer_count;
    const header_slot_count = capacity * 2;
    if (header_slot_count > std.math.maxInt(usize) / stream_capacities.request_header_size) {
        @compileError("HTTP/3 header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream_capacities.request_body_size) {
        @compileError("HTTP/3 request storage size overflows usize");
    }
    if (stream_capacities.request_body_size >
        std.math.maxInt(usize) - stream_capacities.request_header_size)
    {
        @compileError("HTTP/3 receive capacity overflows usize");
    }
    const stream_receive_capacity =
        stream_capacities.request_header_size + stream_capacities.request_body_size;
    // `es_init_max_stream_data_bidi_remote` is a u32 as well.
    if (stream_receive_capacity > std.math.maxInt(c_uint)) {
        @compileError("HTTP/3 receive capacity exceeds lsquic limits");
    }
    if (capacity > std.math.maxInt(usize) / stream_receive_capacity) {
        @compileError("HTTP/3 connection flow-control capacity overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream_capacities.response_header_size) {
        @compileError("HTTP/3 response header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / response_capacity) {
        @compileError("HTTP/3 response storage size overflows usize");
    }
    if (stream_capacities.header_extra_capacity > std.math.maxInt(usize) / 2) {
        @compileError("HTTP/3 header extra capacity overflows usize");
    }
    const header_extra_pointer_count = stream_capacities.header_extra_capacity * 2;
    if (header_extra_pointer_count != 0 and
        capacity > std.math.maxInt(usize) / header_extra_pointer_count)
    {
        @compileError("HTTP/3 header extra storage size overflows usize");
    }
    const header_extra_slot_count = capacity * header_extra_pointer_count;

    const packet_slot_count = @max(@as(usize, 16), capacity * 4);
    const QuicStream = stream.stream_with(stream.lsquic_stream_io, stream_capacities);
    const StreamPool = pool.freelist_pool(QuicStream, capacity);
    const HeaderPool = pool.freelist_pool(HeaderSet, header_slot_count);
    const PacketPool = pool.freelist_pool(PacketSlot, packet_slot_count);

    return struct {
        const Self = @This();

        engine: ?*c.lsquic_engine = null,
        ssl_ctx: *c.SSL_CTX = undefined,
        router: *const Router = undefined,
        udp_fd: std.posix.socket_t = api.invalid_socket,
        local_address: api.Sockaddr = .{},
        settings: c.lsquic_engine_settings = std.mem.zeroes(c.lsquic_engine_settings),
        stream_interface: c.lsquic_stream_if = std.mem.zeroes(c.lsquic_stream_if),
        header_interface: c.lsquic_hset_if = std.mem.zeroes(c.lsquic_hset_if),
        packet_interface: c.lsquic_packout_mem_if = std.mem.zeroes(c.lsquic_packout_mem_if),
        engine_api: c.lsquic_engine_api = std.mem.zeroes(c.lsquic_engine_api),
        stream_pool: StreamPool,
        header_pool: HeaderPool,
        packet_pool: PacketPool,
        header_storage: []u8,
        request_body_storage: []u8,
        response_header_storage: []u8,
        response_body_storage: []u8,
        /// Per-stream capture slots beyond the inline `Request` arrays;
        /// empty when `route_param_extra_capacity` is zero.
        route_param_storage: [][]const u8,
        /// Per-stream request-field slots beyond the inline `Request` arrays;
        /// empty when `stream_capacities.header_extra_capacity` is zero.
        header_extra_storage: [][]const u8,
        active_connections: usize = 0,
        global_acquired: bool = false,
        /// Depth of active lsquic callbacks; cooldown must not re-enter them.
        callback_depth: usize = 0,
        /// Cooldown requested while an engine callback was active.
        cooldown_pending: bool = false,
        in_cooldown: bool = false,

        /// Allocates all stream, header, packet, and payload slabs.
        pub fn init() !Self {
            // lsxpack field lengths are u16. Keep the shared HTTP/1 limit free
            // to exceed this, but never allocate an HTTP/3 engine that cannot
            // represent its own request-header storage.
            if (stream_capacities.request_header_size > std.math.maxInt(u16)) {
                return error.InvalidHttp3Capacity;
            }
            var stream_pool = try StreamPool.init();
            errdefer stream_pool.deinit();
            var header_pool = try HeaderPool.init();
            errdefer header_pool.deinit();
            var packet_pool = try PacketPool.init();
            errdefer packet_pool.deinit();

            const header_storage = try std.heap.page_allocator.alloc(
                u8,
                header_slot_count * stream_capacities.request_header_size,
            );
            errdefer std.heap.page_allocator.free(header_storage);
            const request_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream_capacities.request_body_size,
            );
            errdefer std.heap.page_allocator.free(request_body_storage);
            const response_header_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream_capacities.response_header_size,
            );
            errdefer std.heap.page_allocator.free(response_header_storage);
            const response_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * response_capacity,
            );
            errdefer std.heap.page_allocator.free(response_body_storage);
            // A zero slot count allocates nothing; the allocator returns an
            // empty slice whose free is a no-op.
            const route_param_storage = try std.heap.page_allocator.alloc(
                []const u8,
                route_param_slot_count,
            );
            errdefer std.heap.page_allocator.free(route_param_storage);
            const header_extra_storage = try std.heap.page_allocator.alloc(
                []const u8,
                header_extra_slot_count,
            );
            errdefer std.heap.page_allocator.free(header_extra_storage);

            return .{
                .stream_pool = stream_pool,
                .header_pool = header_pool,
                .packet_pool = packet_pool,
                .header_storage = header_storage,
                .request_body_storage = request_body_storage,
                .response_header_storage = response_header_storage,
                .response_body_storage = response_body_storage,
                .route_param_storage = route_param_storage,
                .header_extra_storage = header_extra_storage,
            };
        }

        /// Applies the fixed engine policy over lsquic's defaults.
        ///
        /// BBRv1 paces against the bottleneck bandwidth estimate, which keeps
        /// queues short and tail latency low on lossy paths; lsquic's default
        /// adaptive controller drops to CUBIC at low RTT.
        pub fn apply_settings(settings: *c.lsquic_engine_settings) void {
            c.lsquic_engine_init_settings(settings, c.LSENG_HTTP_SERVER);
            settings.es_cc_algo = cc_algo_bbr;
            // BBR depends on pacing; pin it so a future default cannot weaken it.
            settings.es_pace_packets = 1;
            settings.es_max_streams_in = @intCast(capacity);
            settings.es_max_inchoate = @intCast(capacity);
            settings.es_max_header_list_size = @intCast(stream_capacities.request_header_size);
            settings.es_max_header_sets = 1;
            settings.es_qpack_dec_max_size = 0;
            settings.es_qpack_dec_max_blocked = 0;
            settings.es_init_max_streams_bidi = @intCast(capacity);
            settings.es_init_max_stream_data_bidi_remote = @intCast(stream_receive_capacity);
            settings.es_init_max_data = @intCast(@min(
                capacity * stream_receive_capacity,
                std.math.maxInt(c_uint),
            ));
            settings.es_max_udp_payload_size_rx = api.max_udp_payload_size;
            settings.es_base_plpmtu = 1200;
            settings.es_max_plpmtu = 1472;
            settings.es_max_batch_size = 16;
            // TLS rejects 0-RTT, so retaining replayable packets has no application value.
            settings.es_max_delayed_0rtt_packets = 0;
            settings.es_rw_once = 1;
            settings.es_proc_time_thresh = 10_000;
        }

        /// Starts the engine and borrows its TLS context and router until `deinit`.
        pub fn start(
            self: *Self,
            ssl_ctx: *c.SSL_CTX,
            router: *const Router,
            udp_fd: std.posix.socket_t,
            local_address: std.Io.net.IpAddress,
        ) !void {
            if (self.engine != null) return error.QuicEngineAlreadyStarted;
            try api.acquire_global();
            self.global_acquired = true;
            errdefer {
                api.release_global();
                self.global_acquired = false;
            }

            self.ssl_ctx = ssl_ctx;
            self.router = router;
            self.udp_fd = udp_fd;
            self.local_address = api.Sockaddr.init(local_address);

            Self.apply_settings(&self.settings);

            var settings_error: [256]u8 = undefined;
            if (c.lsquic_engine_check_settings(
                &self.settings,
                c.LSENG_HTTP_SERVER,
                &settings_error,
                settings_error.len,
            ) != 0) return error.InvalidLsquicSettings;

            self.stream_interface = std.mem.zeroes(c.lsquic_stream_if);
            self.stream_interface.on_new_conn = on_new_connection;
            self.stream_interface.on_conn_closed = on_connection_closed;
            self.stream_interface.on_new_stream = on_new_stream;
            self.stream_interface.on_read = on_stream_read;
            self.stream_interface.on_write = on_stream_write;
            self.stream_interface.on_close = on_stream_close;
            self.stream_interface.on_hset_in = on_header_set_available;

            self.header_interface = std.mem.zeroes(c.lsquic_hset_if);
            self.header_interface.hsi_create_header_set = create_header_set;
            self.header_interface.hsi_prepare_decode = prepare_header_decode;
            self.header_interface.hsi_process_header = process_header;
            self.header_interface.hsi_discard_header_set = discard_header_set;

            self.packet_interface = std.mem.zeroes(c.lsquic_packout_mem_if);
            self.packet_interface.pmi_allocate = allocate_packet;
            self.packet_interface.pmi_release = release_packet;
            self.packet_interface.pmi_return = release_packet;

            self.engine_api = std.mem.zeroes(c.lsquic_engine_api);
            self.engine_api.ea_settings = &self.settings;
            self.engine_api.ea_stream_if = &self.stream_interface;
            self.engine_api.ea_stream_if_ctx = self;
            self.engine_api.ea_packets_out = packets_out;
            self.engine_api.ea_packets_out_ctx = self;
            self.engine_api.ea_get_ssl_ctx = get_ssl_context;
            self.engine_api.ea_hsi_if = &self.header_interface;
            self.engine_api.ea_hsi_ctx = self;
            self.engine_api.ea_pmi = &self.packet_interface;
            self.engine_api.ea_pmi_ctx = self;

            self.engine = c.lsquic_engine_new(c.LSENG_HTTP_SERVER, &self.engine_api) orelse {
                return error.LsquicEngineCreationFailed;
            };
        }

        /// Destroys the engine and releases every setup-time slab.
        pub fn deinit(self: *Self) void {
            if (self.engine) |engine| c.lsquic_engine_destroy(engine);
            self.engine = null;
            self.udp_fd = api.invalid_socket;

            std.debug.assert(self.stream_pool.count_active() == 0);
            std.debug.assert(self.header_pool.count_active() == 0);
            std.debug.assert(self.packet_pool.count_active() == 0);
            std.debug.assert(self.active_connections == 0);
            if (self.global_acquired) api.release_global();
            self.global_acquired = false;

            std.heap.page_allocator.free(self.response_body_storage);
            std.heap.page_allocator.free(self.response_header_storage);
            std.heap.page_allocator.free(self.request_body_storage);
            std.heap.page_allocator.free(self.header_storage);
            std.heap.page_allocator.free(self.route_param_storage);
            std.heap.page_allocator.free(self.header_extra_storage);
            self.packet_pool.deinit();
            self.header_pool.deinit();
            self.stream_pool.deinit();
        }

        /// Submits one peer datagram and immediately services ready connections.
        pub fn process_datagram(self: *Self, data: []const u8, peer: std.Io.net.IpAddress) void {
            const engine = self.engine orelse return;
            if (data.len == 0 or data.len > api.max_udp_payload_size) return;

            self.callback_depth += 1;
            defer self.leave_callback();

            const peer_address = api.Sockaddr.init(peer);
            const result = c.lsquic_engine_packet_in(
                engine,
                data.ptr,
                data.len,
                self.local_address.ptr(),
                peer_address.ptr(),
                self,
                0,
            );
            if (result < 0) {
                log.warn("packet_in failed for {d}-byte datagram; dropping", .{data.len});
                return;
            }
            self.process();
        }

        /// Flushes pending packets and advances ready lsquic connections.
        pub fn process(self: *Self) void {
            const engine = self.engine orelse return;
            self.callback_depth += 1;
            defer self.leave_callback();

            if (c.lsquic_engine_has_unsent_packets(engine) != 0) {
                c.lsquic_engine_send_unsent_packets(engine);
            }
            c.lsquic_engine_process_conns(engine);
        }

        /// Begins graceful engine shutdown and advances affected connections.
        ///
        /// Safe to call from inside an H3 callback: the engine defers the
        /// cooldown until the active `lsquic_engine_process_conns` unwinds,
        /// because lsquic asserts on nested processing.
        pub fn cooldown(self: *Self) void {
            if (self.engine == null) return;
            if (self.callback_depth != 0) {
                self.cooldown_pending = true;
                return;
            }
            self.run_cooldown();
        }

        fn leave_callback(self: *Self) void {
            self.callback_depth -= 1;
            if (self.callback_depth == 0 and self.cooldown_pending) {
                self.cooldown_pending = false;
                self.run_cooldown();
            }
        }

        fn run_cooldown(self: *Self) void {
            const engine = self.engine orelse return;
            if (self.in_cooldown) return;
            self.in_cooldown = true;
            defer self.in_cooldown = false;
            c.lsquic_engine_cooldown(engine);
            c.lsquic_engine_process_conns(engine);
        }

        /// Returns a bounded delay until the next engine service call.
        ///
        /// lsquic's earliest-advance tick still pulls the timer back in when
        /// work is pending; the one-second ceiling only keeps an idle listener
        /// from waking twenty times per second.
        pub fn next_timeout_ms(self: *Self) u64 {
            const engine = self.engine orelse return 1000;
            var microseconds: c_int = 0;
            if (c.lsquic_engine_earliest_adv_tick(engine, &microseconds) == 0) return 1000;
            if (microseconds <= 0) return 1;
            const rounded: u64 = @divTrunc(@as(u64, @intCast(microseconds)) + 999, 1000);
            return std.math.clamp(rounded, 1, 1000);
        }

        fn acquire_header_set(
            self: *Self,
            is_trailer: bool,
            header_extra_names: [][]const u8,
            header_extra_values: [][]const u8,
        ) ?*HeaderSet {
            const header_set = self.header_pool.acquire() orelse return null;
            const index = self.header_pool.index_of(header_set) orelse unreachable;
            const storage_start = index * stream_capacities.request_header_size;
            const storage = self.header_storage[storage_start .. storage_start + stream_capacities.request_header_size];
            if (is_trailer) {
                header_set.reset_trailer(
                    self,
                    release_header_set,
                    storage,
                    header_extra_names,
                    header_extra_values,
                    stream_capacities,
                );
            } else {
                header_set.reset(
                    self,
                    release_header_set,
                    storage,
                    header_extra_names,
                    header_extra_values,
                    stream_capacities,
                );
            }
            return header_set;
        }

        fn release_header_set(context: *anyopaque, header_set: *HeaderSet) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.header_pool.release(header_set));
        }

        fn acquire_stream(self: *Self, lsquic_stream: *c.lsquic_stream) ?*QuicStream {
            const quic_stream = self.stream_pool.acquire() orelse return null;
            const index = self.stream_pool.index_of(quic_stream) orelse unreachable;
            const body_start = index * stream_capacities.request_body_size;
            const response_header_start = index * stream_capacities.response_header_size;
            const response_body_start = index * response_capacity;
            const route_param_start = index * route_param_pointer_count;
            const header_extra_start = index * header_extra_pointer_count;
            const route_param_names: [][]const u8 = if (route_param_extra_capacity == 0)
                &.{}
            else
                self.route_param_storage[route_param_start .. route_param_start + route_param_extra_capacity];
            const route_param_values: [][]const u8 = if (route_param_extra_capacity == 0)
                &.{}
            else
                self.route_param_storage[route_param_start + route_param_extra_capacity .. route_param_start + route_param_pointer_count];
            const header_extra_names: [][]const u8 = if (stream_capacities.header_extra_capacity == 0)
                &.{}
            else
                self.header_extra_storage[header_extra_start .. header_extra_start + stream_capacities.header_extra_capacity];
            const header_extra_values: [][]const u8 = if (stream_capacities.header_extra_capacity == 0)
                &.{}
            else
                self.header_extra_storage[header_extra_start + stream_capacities.header_extra_capacity .. header_extra_start + header_extra_pointer_count];
            quic_stream.reset(
                self,
                release_stream,
                lsquic_stream,
                self.router,
                self.request_body_storage[body_start .. body_start + stream_capacities.request_body_size],
                self.response_body_storage[response_body_start .. response_body_start + response_capacity],
                self.response_header_storage[response_header_start .. response_header_start + stream_capacities.response_header_size],
                route_param_names,
                route_param_values,
                header_extra_names,
                header_extra_values,
            );
            return quic_stream;
        }

        fn release_stream(context: *anyopaque, quic_stream: *QuicStream) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.stream_pool.release(quic_stream));
        }

        fn on_new_connection(context: ?*anyopaque, connection: ?*c.lsquic_conn) callconv(.c) ?*c.lsquic_conn_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const conn = connection orelse return null;
            if (self.active_connections >= capacity) {
                c.lsquic_conn_abort(conn);
                return null;
            }
            self.active_connections += 1;
            return @ptrCast(self);
        }

        fn on_connection_closed(connection: ?*c.lsquic_conn) callconv(.c) void {
            const conn = connection orelse return;
            const context = c.lsquic_conn_get_ctx(conn) orelse return;
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.active_connections != 0) self.active_connections -= 1;
            c.lsquic_conn_set_ctx(conn, null);
        }

        fn on_new_stream(context: ?*anyopaque, lsquic_stream: ?*c.lsquic_stream) callconv(.c) ?*c.lsquic_stream_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const raw_stream = lsquic_stream orelse return null;
            const quic_stream = self.acquire_stream(raw_stream) orelse {
                _ = c.lsquic_stream_close(raw_stream);
                return null;
            };
            _ = c.lsquic_stream_wantread(raw_stream, 1);
            return @ptrCast(quic_stream);
        }

        fn on_stream_read(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_read();
        }

        fn on_stream_write(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_write();
        }

        fn on_stream_close(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_close();
        }

        fn on_header_set_available(
            lsquic_stream: ?*c.lsquic_stream,
            context: ?*c.lsquic_stream_ctx,
        ) callconv(.c) void {
            const raw_stream = lsquic_stream orelse return;
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            const raw_header_set = c.lsquic_stream_get_hset(raw_stream) orelse {
                _ = c.lsquic_stream_close(raw_stream);
                return;
            };
            const header_set: *HeaderSet = @ptrCast(@alignCast(raw_header_set));
            quic_stream.attach_headers(header_set);
        }

        fn create_header_set(
            context: ?*anyopaque,
            lsquic_stream: ?*c.lsquic_stream,
            is_push_promise: c_int,
        ) callconv(.c) ?*anyopaque {
            if (is_push_promise != 0) return null;
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            var quic_stream: ?*QuicStream = null;
            if (lsquic_stream) |raw_stream| {
                if (c.lsquic_stream_get_ctx(raw_stream)) |raw_context| {
                    quic_stream = @ptrCast(@alignCast(raw_context));
                }
            }
            const is_trailer = if (quic_stream) |active|
                active.request_phase != .waiting_headers
            else
                false;
            const header_extra_names: [][]const u8 = if (quic_stream) |active|
                active.header_extra_names
            else
                &.{};
            const header_extra_values: [][]const u8 = if (quic_stream) |active|
                active.header_extra_values
            else
                &.{};
            return self.acquire_header_set(is_trailer, header_extra_names, header_extra_values);
        }

        fn prepare_header_decode(
            context: ?*anyopaque,
            existing: ?*c.lsxpack_header,
            required: usize,
        ) callconv(.c) ?*c.lsxpack_header {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return null));
            return header_set.prepare_decode(existing, required);
        }

        fn process_header(context: ?*anyopaque, header: ?*c.lsxpack_header) callconv(.c) c_int {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return -1));
            return if (header_set.process_header(header)) 0 else 1;
        }

        fn discard_header_set(context: ?*anyopaque) callconv(.c) void {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return));
            header_set.release();
        }

        fn packets_out(
            context: ?*anyopaque,
            specs: [*c]const c.lsquic_out_spec,
            count: c_uint,
        ) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(context orelse return -1));
            return api.send_packets(self.udp_fd, specs, count);
        }

        fn get_ssl_context(
            peer_context: ?*anyopaque,
            _: [*c]const c.struct_sockaddr,
        ) callconv(.c) ?*c.SSL_CTX {
            const self: *Self = @ptrCast(@alignCast(peer_context orelse return null));
            return self.ssl_ctx;
        }

        fn allocate_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            _: ?*c.lsquic_conn_ctx,
            size: c_ushort,
            _: u8,
        ) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            if (size == 0 or size > api.max_udp_payload_size) return null;
            const slot = self.packet_pool.acquire() orelse return null;
            return &slot.bytes;
        }

        fn release_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            buffer: ?*anyopaque,
            _: u8,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            const raw_buffer = buffer orelse return;
            const slot: *PacketSlot = @ptrCast(@alignCast(raw_buffer));
            std.debug.assert(self.packet_pool.release(slot));
        }
    };
}
