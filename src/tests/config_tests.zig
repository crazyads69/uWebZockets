const std = @import("std");
const support = @import("test_support");

const app_module = support.app;
const builder_module = support.builder;
const config_module = support.config;
const rejection = support.rejection;
const ServerConfig = config_module.ServerConfig;
const Preset = ServerConfig.Preset;

/// Wraps a parent allocator and counts application-level allocations.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = deallocate,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address) orelse
            return null;
        self.allocations += 1;
        self.live_bytes += len;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, return_address)) {
            return false;
        }
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const mapped = self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return mapped;
    }

    fn deallocate(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.live_bytes -= memory.len;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

test "config: presets validate and plan contiguous slabs" {
    inline for (.{ Preset.microservice, Preset.websocket_chat, Preset.file_server }) |preset| {
        try preset.validate();
        const bytes = try preset.slab_bytes();
        try std.testing.expect(bytes > preset.max_connections * preset.write_queue_size);
        try std.testing.expect(bytes > preset.max_connections * preset.max_body_size);
    }

    try std.testing.expectError(error.InvalidConnectionCapacity, (ServerConfig{
        .max_connections = 0,
    }).validate());
    try std.testing.expectError(error.InvalidWebSocketMessageCapacity, (ServerConfig{
        .max_ws_message_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidWriteQueueCapacity, (ServerConfig{
        .write_queue_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidBodyCapacity, (ServerConfig{
        .max_body_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidIdleTimeout, (ServerConfig{
        .idle_timeout_ms = std.math.maxInt(i64) + 1,
    }).validate());
}

test "config: request stride covers the configured body" {
    const config = ServerConfig{
        .max_connections = 2,
        .max_body_size = 50 * 1024 * 1024,
    };
    const stride = try config.request_buffer_stride();
    try std.testing.expect(stride >= config.max_body_size);
    try std.testing.expectEqual(
        @as(usize, 0),
        stride % config_module.request_buffer_alignment,
    );

    const headroom = stride - config.max_body_size;
    try std.testing.expect(headroom >= support.http_parser.max_header_size);
    try std.testing.expect(headroom >= support.http_parser.max_request_line_size);
}

test "config: with derives a modified copy" {
    const derived = Preset.microservice.with(.{
        .max_connections = 3,
        .compression = true,
    });
    try std.testing.expectEqual(@as(usize, 3), derived.max_connections);
    try std.testing.expect(derived.compression);
    try std.testing.expectEqual(
        Preset.microservice.max_body_size,
        derived.max_body_size,
    );
}

test "config: configured request line and header sizes drive the stride" {
    const base = ServerConfig{};
    const grown = ServerConfig{
        .max_request_line_size = 16 * 1024,
        .max_header_size = 32 * 1024,
    };

    const grown_extra = (16 * 1024 - support.http_parser.max_request_line_size) +
        (32 * 1024 - support.http_parser.max_header_size);
    try std.testing.expectEqual(
        (try base.request_buffer_stride()) + grown_extra,
        try grown.request_buffer_stride(),
    );

    const policy = grown.rejection_policy();
    try std.testing.expectEqual(@as(usize, 32 * 1024), policy.max_header_size);
    try std.testing.expectEqual(grown.max_body_size, policy.max_body_size);
}

test "config: extra header storage grows with max_header_count" {
    const config = ServerConfig{ .max_connections = 8, .max_header_count = 256 };
    try config.validate();

    const capacity = try config.extra_header_capacity();
    try std.testing.expectEqual(@as(usize, 256 - support.http_request.max_headers), capacity);
    const stride = try config.extra_header_stride();
    try std.testing.expectEqual(capacity * 2 * @sizeOf([]const u8), stride);
    try std.testing.expectEqual(
        @as(usize, 0),
        stride % config_module.request_buffer_alignment,
    );

    const default_bytes = try (ServerConfig{ .max_connections = 8 }).slab_bytes();
    const total = try config.slab_bytes();
    try std.testing.expect(total > default_bytes);

    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(@as(usize, 8 * stride), layout.header_extras.len);
    try std.testing.expectEqual(stride, layout.extra_header_stride);
}

test "config: validate rejects invalid request limits" {
    try std.testing.expectError(
        error.InvalidRequestLineCapacity,
        (ServerConfig{ .max_request_line_size = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHeaderCapacity,
        (ServerConfig{ .max_header_size = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHeaderCapacity,
        (ServerConfig{ .max_header_count = support.http_request.max_headers - 1 }).validate(),
    );
    try (ServerConfig{ .max_header_count = support.http_request.max_headers }).validate();

    const huge = ServerConfig{ .max_header_count = std.math.maxInt(usize) / 2 };
    try std.testing.expectError(error.SlabSizeOverflow, huge.validate());
}

test "config: with merges request limit overrides" {
    const derived = (ServerConfig{}).with(.{
        .max_request_line_size = 4096,
        .max_header_size = 8192,
        .max_header_count = 96,
    });
    try std.testing.expectEqual(@as(usize, 4096), derived.max_request_line_size);
    try std.testing.expectEqual(@as(usize, 8192), derived.max_header_size);
    try std.testing.expectEqual(@as(usize, 96), derived.max_header_count);
    try std.testing.expectEqual((ServerConfig{}).max_body_size, derived.max_body_size);
    try std.testing.expectEqual(
        (ServerConfig{}).max_header_size,
        (ServerConfig{}).with(.{}).max_header_size,
    );
}

test "config: default slab carries the router region at the end" {
    const config = ServerConfig{};
    const router_bytes = try config.router_storage_bytes();
    try std.testing.expectEqual(@as(usize, 874_112), router_bytes);

    const total = try config.slab_bytes();
    // The connection slab dominates the default footprint. The inline route
    // capture accessors added a pointer pair and a count to `TcpConnection`,
    // the per-stream HTTP/2 session storage moved out of `TcpConnection` into
    // a carved per-connection region, the per-stream HTTP/2 response status
    // array added sixteen bytes per connection, the runtime-selectable
    // libxev wrappers added the epoll variants to every per-connection
    // completion, and the static-route index added its 512 hash slots, 512
    // node slots, and 256 parent links (5_632 bytes) to the router region,
    // moving 681_711_744 to this total. TRACE adds one 8-byte handler slot per
    // node, moving 681_717_376 to 681_727_616. The HTTP gzip pool pointer adds
    // eight bytes per connection, moving the total to 681_735_808. The
    // incremental parser scan cursor adds two usize fields per connection,
    // moving the total to 681_752_192.
    try std.testing.expectEqual(@as(usize, 681_752_192), total);
    // The default route-param extras stride is zero: the region extends the
    // slab by exactly one router region's bytes.
    try std.testing.expectEqual(@as(usize, 0), try config.extra_route_param_stride());
    try std.testing.expectEqual(@as(usize, 680_878_080), total - router_bytes);
}

test "config: slab bytes grow with each router capacity knob" {
    const base = ServerConfig{};
    const base_bytes = try base.slab_bytes();
    const base_router = try base.router_storage_bytes();
    const overrides = [_]ServerConfig.Overrides{
        .{ .max_route_nodes = base.max_route_nodes + 16 },
        .{ .max_pattern_routes = base.max_pattern_routes + 4 },
        .{ .max_middleware = base.max_middleware + 4 },
        .{ .max_route_path_size = base.max_route_path_size + 64 },
        .{ .max_route_registry_size = base.max_route_registry_size + 512 },
    };
    for (overrides) |override| {
        const grown = base.with(override);
        try std.testing.expect(try grown.router_storage_bytes() > base_router);
        try std.testing.expect(try grown.slab_bytes() > base_bytes);
    }
}

test "config: slab bytes grow with each HTTP/2 capacity knob" {
    const base = ServerConfig{ .max_connections = 2 };
    const base_bytes = try base.slab_bytes();
    const base_h2 = try base.h2_session_bytes();
    const overrides = [_]ServerConfig.Overrides{
        .{ .max_h2_header_block_size = base.max_h2_header_block_size + 4096 },
        .{ .max_h2_body_size = base.max_h2_body_size + 4096 },
        .{ .max_h2_response_header_size = base.max_h2_response_header_size + 4096 },
        .{ .max_h2_response_header_count = base.max_h2_response_header_count + 8 },
        // Decoded field count drives the per-stream header-overflow pointers.
        .{ .max_header_count = base.max_header_count + 32 },
    };
    for (overrides) |override| {
        const grown = base.with(override);
        try grown.validate();
        try std.testing.expect(try grown.h2_session_bytes() > base_h2);
        try std.testing.expect(try grown.slab_bytes() > base_bytes);
    }

    const defaults = ServerConfig{};
    try std.testing.expectEqual(@as(usize, 16 * 1024), defaults.max_h2_header_block_size);
    try std.testing.expectEqual(@as(usize, 16 * 1024), defaults.max_h2_body_size);
    try std.testing.expectEqual(@as(usize, 4 * 1024), defaults.max_h2_response_header_size);
    try std.testing.expectEqual(@as(usize, 32), defaults.max_h2_response_header_count);
}

test "config: validate rejects invalid HTTP/2 capacities" {
    const invalid = [_]ServerConfig{
        .{ .max_h2_header_block_size = 0 },
        .{ .max_h2_body_size = 0 },
        .{ .max_h2_response_header_size = 0 },
        .{ .max_h2_response_header_count = 0 },
        .{ .max_h2_body_size = std.math.maxInt(usize) / 2 },
    };
    for (invalid) |config| {
        try std.testing.expectError(error.InvalidHttp2Capacity, config.validate());
        try std.testing.expectError(error.InvalidHttp2Capacity, config.h2_session_bytes());
    }

    try (ServerConfig{
        .max_h2_header_block_size = 1024,
        .max_h2_body_size = 1024,
        .max_h2_response_header_size = 512,
        .max_h2_response_header_count = 4,
    }).validate();
}

test "config: H2 session storage is carved per connection and initializes" {
    const config = ServerConfig{ .max_connections = 2, .max_h2_body_size = 8 * 1024 };
    try config.validate();
    const stride = try config.h2_session_stride();
    try std.testing.expect(stride >= try config.h2_session_bytes());
    try std.testing.expectEqual(@as(usize, 0), stride % support.tcp.Http2Session.storage_alignment);

    const total = try config_module.required_bytes(config);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(@as(usize, 2 * stride), layout.h2_sessions.len);
    try std.testing.expectEqual(stride, layout.h2_session_stride);

    const capacities = config.h2_capacities();
    for (0..2) |index| {
        const start = index * layout.h2_session_stride;
        const storage = try support.tcp.Http2Session.carve_storage(
            layout.h2_sessions[start .. start + layout.h2_session_stride],
            capacities,
        );
        const session = try support.tcp.Http2Session.init(storage);
        try std.testing.expect(session.requests.len == support.tcp.max_http2_streams);
        try std.testing.expectEqual(
            capacities.dynamic_table_size,
            session.dynamic_bytes.len,
        );
    }
}

test "config: route param capacity sizes the slab" {
    const base = ServerConfig{ .max_connections = 2 };
    const raised = base.with(.{ .max_route_params = 24 });
    try raised.validate();

    try std.testing.expectEqual(@as(usize, 0), try base.extra_route_param_stride());
    try std.testing.expectEqual(@as(usize, 8), try raised.extra_route_param_capacity());
    const stride = try raised.extra_route_param_stride();
    try std.testing.expectEqual(@as(usize, 8 * 2 * @sizeOf([]const u8)), stride);
    try std.testing.expect((try raised.slab_bytes()) > (try base.slab_bytes()));

    try std.testing.expectError(
        error.InvalidRouterCapacity,
        (ServerConfig{
            .max_route_params = support.http_request.max_route_params - 1,
        }).validate(),
    );
    try (ServerConfig{
        .max_route_params = support.http_request.max_route_params,
    }).validate();
    try std.testing.expectError(
        error.SlabSizeOverflow,
        (ServerConfig{ .max_route_params = std.math.maxInt(usize) }).validate(),
    );

    try std.testing.expectEqual(@as(usize, 24), raised.router_capacities().max_route_params);
    try std.testing.expectEqual(
        support.http_request.max_route_params,
        (ServerConfig{}).router_capacities().max_route_params,
    );

    const total = try config_module.required_bytes(raised);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, raised);
    try std.testing.expectEqual(@as(usize, 2 * stride), layout.route_param_extras.len);
    try std.testing.expectEqual(stride, layout.extra_route_param_stride);
}

test "config: validate rejects out-of-range router capacities" {
    const default_path_size = (ServerConfig{}).max_route_path_size;
    const invalid = [_]ServerConfig{
        .{ .max_route_nodes = 0 },
        .{ .max_route_nodes = std.math.maxInt(u16) + 1 },
        .{ .max_route_nodes = std.math.maxInt(usize) },
        .{ .max_pattern_routes = std.math.maxInt(u8) + 1 },
        .{ .max_middleware = std.math.maxInt(u8) + 1 },
        .{ .max_route_path_size = 0 },
        .{ .max_route_path_size = std.math.maxInt(u16) + 1 },
        .{ .max_route_registry_size = default_path_size - 1 },
    };
    for (invalid) |config| {
        try std.testing.expectError(error.InvalidRouterCapacity, config.validate());
        try std.testing.expectError(
            error.InvalidRouterCapacity,
            config.router_storage_bytes(),
        );
    }

    try (ServerConfig{ .max_route_nodes = 1 }).validate();
    try (ServerConfig{
        .max_route_path_size = std.math.maxInt(u16),
        .max_route_registry_size = std.math.maxInt(u16),
    }).validate();
}

test "config: with merges router capacity overrides" {
    const derived = (ServerConfig{}).with(.{
        .max_route_nodes = 300,
        .max_pattern_routes = 8,
        .max_middleware = 12,
        .max_route_path_size = 1024,
        .max_route_registry_size = 32 * 1024,
    });
    try std.testing.expectEqual(@as(usize, 300), derived.max_route_nodes);
    try std.testing.expectEqual(@as(usize, 8), derived.max_pattern_routes);
    try std.testing.expectEqual(@as(usize, 12), derived.max_middleware);
    try std.testing.expectEqual(@as(usize, 1024), derived.max_route_path_size);
    try std.testing.expectEqual(@as(usize, 32 * 1024), derived.max_route_registry_size);
    try std.testing.expectEqual((ServerConfig{}).max_connections, derived.max_connections);
    try std.testing.expectEqual(
        (ServerConfig{}).max_route_nodes,
        (ServerConfig{}).with(.{}).max_route_nodes,
    );

    const capacities = derived.router_capacities();
    try std.testing.expectEqual(@as(usize, 300), capacities.max_nodes);
    try std.testing.expectEqual(@as(usize, 8), capacities.max_pattern_routes);
    try std.testing.expectEqual(@as(usize, 12), capacities.max_middleware);
    try std.testing.expectEqual(@as(usize, 1024), capacities.max_route_path_size);
    try std.testing.expectEqual(@as(usize, 32 * 1024), capacities.registry_storage_size);
}

test "config: router region is aligned, ends the slab, and carves" {
    const config = ServerConfig{
        .max_connections = 4,
        .max_route_nodes = 32,
        .max_pattern_routes = 8,
        .max_middleware = 6,
        .max_route_path_size = 512,
        .max_route_registry_size = 4096,
    };
    const total = try config_module.required_bytes(config);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(total, layout.total_bytes);
    try std.testing.expectEqual(try config.router_storage_bytes(), layout.router_storage.len);
    try std.testing.expect(layout.router_storage.len >= config.max_route_registry_size);
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(layout.router_storage.ptr) % support.radix.storage_alignment,
    );
    const slab_start = @intFromPtr(slab.ptr);
    const router_start = @intFromPtr(layout.router_storage.ptr);
    try std.testing.expect(router_start >= slab_start);
    try std.testing.expect(router_start + layout.router_storage.len <= slab_start + slab.len);
    try std.testing.expectEqual(slab_start + total, router_start + layout.router_storage.len);

    const storage = try support.radix.carve_storage(
        layout.router_storage,
        config.router_capacities(),
    );
    try std.testing.expectEqual(@as(usize, 32), storage.segment_offsets.len);
    try std.testing.expectEqual(@as(usize, 8), storage.pattern_routes.len);
    try std.testing.expectEqual(@as(usize, 6), storage.middleware.len);
    try std.testing.expectEqual(@as(usize, 512), storage.max_route_path_size);
    try std.testing.expectEqual(@as(usize, 4096), storage.registry_storage.len);
}

test "config: builder exposes router capacity knobs" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0)
        .with_max_route_nodes(300)
        .with_max_pattern_routes(16)
        .with_max_middleware(12)
        .with_max_route_path_size(1024)
        .with_max_route_params(24)
        .with_max_route_registry_size(32 * 1024);

    const configuration = builder.configuration();
    try std.testing.expectEqual(@as(usize, 300), configuration.max_route_nodes);
    try std.testing.expectEqual(@as(usize, 16), configuration.max_pattern_routes);
    try std.testing.expectEqual(@as(usize, 12), configuration.max_middleware);
    try std.testing.expectEqual(@as(usize, 1024), configuration.max_route_path_size);
    try std.testing.expectEqual(@as(usize, 24), configuration.max_route_params);
    try std.testing.expectEqual(@as(usize, 32 * 1024), configuration.max_route_registry_size);

    var server = try builder.build(std.testing.allocator);
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 300), server.router_storage.segment_offsets.len);
    try std.testing.expectEqual(@as(usize, 16), server.router_storage.pattern_routes.len);
    try std.testing.expectEqual(@as(usize, 12), server.router_storage.middleware.len);
    try std.testing.expectEqual(@as(usize, 1024), server.router_storage.max_route_path_size);
    try std.testing.expectEqual(@as(usize, 24), server.router_storage.max_route_params);
    try std.testing.expectEqual(@as(usize, 32 * 1024), server.router_storage.registry_storage.len);
    try std.testing.expectEqual(@as(usize, 8), server.extra_route_param_capacity);
    try std.testing.expectEqual(
        @as(usize, 2 * server.extra_route_param_stride),
        server.route_param_extras.len,
    );
    try std.testing.expect(
        @intFromPtr(server.router_storage.route_storage.ptr) >= @intFromPtr(server.slab.ptr),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(server.router_storage.segment_offsets.ptr) % @alignOf(u32),
    );
    try std.testing.expect(!server.router_bound);
    _ = try server.get("/health", dummy_handler);
    try std.testing.expect(server.router_bound);
    // Root plus the newly inserted "/health" segment.
    try std.testing.expectEqual(@as(u16, 2), server.router.node_count);
}

test "config: carve partitions one slab into disjoint aligned regions" {
    const config = ServerConfig{
        .max_connections = 4,
        .max_ws_message_size = 1024,
        .write_queue_size = 2048,
        .max_body_size = 4096,
        .compression = true,
    };
    const total = try config_module.required_bytes(config);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(total, layout.total_bytes);
    try std.testing.expectEqual(@as(usize, 4), layout.pool_storage.len);
    try std.testing.expectEqual(@as(usize, 4), layout.freelist.len);
    try std.testing.expectEqual(
        @as(usize, 4 * layout.request_buffer_stride),
        layout.request_buffers.len,
    );
    try std.testing.expectEqual(@as(usize, 4 * 2048), layout.write_queues.len);
    try std.testing.expectEqual(@as(usize, 4 * 1024), layout.ws_messages.len);
    try std.testing.expectEqual(
        @as(usize, 4 * layout.compression_stride),
        layout.compression_scratch.len,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(layout.pool_storage.ptr) % @alignOf(support.tcp.TcpConnection),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(layout.write_queues.ptr) % config_module.write_queue_alignment,
    );

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.SlabTooSmall, config_module.carve(&small, config));
}

test "config: builder builds one slab and reports its size" {
    const allocator = std.testing.allocator;
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0);
    try std.testing.expectEqual(@as(u64, 0), builder.configuration().idle_timeout_ms);

    var server = try builder.build(allocator);
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 8192), server.max_body_size);
    try std.testing.expectEqual(
        @as(usize, 2),
        server.request_buffers.len / server.request_buffer_stride,
    );
    try std.testing.expectEqual(builder.slab_bytes() catch 0, server.slab.len);
}

test "pool: from_slices adopts caller storage without owning it" {
    var storage: [4]u32 = undefined;
    var freelist: [4]usize = undefined;
    var pool = try support.pool.freelist_pool(u32, 4).from_slices(&storage, &freelist);

    const slot = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());
    try std.testing.expect(pool.release(slot));
    pool.deinit();

    var short: [2]usize = undefined;
    try std.testing.expectError(
        error.StorageCapacityMismatch,
        support.pool.freelist_pool(u32, 4).from_slices(&storage, &short),
    );
}

test "parser: per-connection body policy overrides the default" {
    const wire = "POST / HTTP/1.1\r\nHost: example\r\nContent-Length: 9\r\n\r\nhello wor";
    var buffer: [wire.len]u8 = undefined;
    @memcpy(&buffer, wire);

    var default_request = support.http_request.Request{};
    var default_parser = support.http_parser.HttpParser{};
    _ = support.http_parser.consume(&default_parser, &default_request, &buffer);
    try std.testing.expectEqual(support.http_parser.ParserState.done, default_parser.state);

    var limited_request = support.http_request.Request{};
    var limited_parser = support.http_parser.HttpParser{ .max_body_size = 8 };
    _ = support.http_parser.consume(&limited_parser, &limited_request, &buffer);
    try std.testing.expectEqual(
        support.http_parser.ParserState.error_too_large,
        limited_parser.state,
    );
}

test "rejection: documents name the configured limits" {
    var buffer: [rejection.max_document_bytes]u8 = undefined;

    const policy = rejection.RejectionPolicy{
        .max_body_size = 16 * 1024,
        .max_header_size = 16 * 1024,
    };
    const body = policy.payload_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, body, "16KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "'max_body_size'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"payload_too_large\"") != null);

    const headers = policy.headers_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, headers, "16KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "\"headers_too_large\"") != null);

    const fifty = rejection.RejectionPolicy{ .max_body_size = 50 * 1024 * 1024 };
    const large = fifty.payload_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, large, "50MB") != null);
}

test "rejection: format_bytes renders compact binary units" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0B", rejection.format_bytes(0, &buffer));
    try std.testing.expectEqualStrings("512B", rejection.format_bytes(512, &buffer));
    try std.testing.expectEqualStrings("1KB", rejection.format_bytes(1024, &buffer));
    try std.testing.expectEqualStrings("1.5KB", rejection.format_bytes(1536, &buffer));
    try std.testing.expectEqualStrings("16MB", rejection.format_bytes(16 * 1024 * 1024, &buffer));
}

test "deflate: planner bound covers negotiated compression scratch" {
    var context = try support.ws_deflate.Context.init(6);
    defer context.deinit();

    for ([_]usize{ 1, 64, 1024, 16 * 1024, 64 * 1024, 1024 * 1024 }) |input_len| {
        const negotiated = try context.scratch_bound(input_len);
        const planned = try support.ws_deflate.worst_case_scratch_bound(input_len);
        try std.testing.expect(planned >= negotiated);
    }
}

test "deflate: configured workers open the compressor pool at startup" {
    const TestApp = app_module.configured_app_with_timeout(1, 1024, 4096, 0);
    const config = comptime config_module.default_config.with(.{
        .max_connections = 1,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .compression = true,
        .http_compression = true,
    });
    var server = try TestApp.init_configured(std.testing.io, std.testing.allocator, config);
    defer server.deinit();

    // The codec exists before any route is registered or request is parsed.
    try std.testing.expect(server.ws_deflate != null);
    try std.testing.expect(server.http_compression != null);
    try std.testing.expect(server.ws_compression_storage.len != 0);
}

test "config: app init carves request buffers out of the slab" {
    const TestApp = app_module.configured_app_with_timeout(2, 1024, 4096, 0);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();

    const expected_config = ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
    };
    const stride = try expected_config.request_buffer_stride();

    try std.testing.expectEqual(
        @as(usize, support.http_parser.default_max_body_size),
        server.max_body_size,
    );
    try std.testing.expectEqual(@as(usize, 2 * stride), server.request_buffers.len);
}

test "config: oversized capacities fail without panicking" {
    const huge = ServerConfig{ .max_connections = std.math.maxInt(usize) };
    try std.testing.expectError(error.SlabSizeOverflow, huge.slab_bytes());

    const wide_digits = ServerConfig{
        .max_connections = std.math.maxInt(usize) / 2,
        .max_body_size = std.math.maxInt(usize) / 2,
    };
    try std.testing.expectError(error.SlabSizeOverflow, wide_digits.slab_bytes());
}

fn dummy_handler(_: *support.http_request.Request, _: *support.http_response.Response) void {}

test "config: datagram and bypass presets validate and plan slabs" {
    inline for (.{ Preset.kernel_bypass, Preset.webtransport_realtime }) |preset| {
        try preset.validate();
        try std.testing.expect((try preset.slab_bytes()) > 0);
    }

    try std.testing.expectError(
        error.InvalidDatagramCapacity,
        (ServerConfig{ .max_datagram_size = 0, .datagram_slots = 4 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidDatagramCapacity,
        (ServerConfig{ .max_datagram_size = 100, .datagram_slots = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidTransportConfiguration,
        (ServerConfig{ .transport = .kernel_bypass, .xdp_frame_size = 3000 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidMetricsPath,
        (ServerConfig{ .observability = true, .metrics_path = "metrics" }).validate(),
    );
    try std.testing.expectEqual(
        std.heap.page_size_min,
        (ServerConfig{ .transport = .kernel_bypass }).required_alignment(),
    );
}

test "config: datagram regions are one fixed stride per connection" {
    const config = ServerConfig{
        .max_connections = 4,
        .max_datagram_size = 256,
        .datagram_slots = 8,
    };
    const total = try config_module.required_bytes(config);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(@as(usize, 32), layout.datagram_session_ids.len);
    try std.testing.expectEqual(@as(usize, 32), layout.datagram_sequences.len);
    try std.testing.expectEqual(@as(usize, 32), layout.datagram_payload_lengths.len);
    try std.testing.expectEqual(@as(usize, 4), layout.datagram_rings.len);
    try std.testing.expectEqual(@as(usize, 8 * 256), layout.datagram_stride);
    try std.testing.expectEqual(@as(usize, 4 * 8 * 256), layout.datagram_payloads.len);
    try std.testing.expectEqual(@as(usize, 0), layout.xdp_umem.len);
}

test "config: datagram router rejects duplicates and unknown paths" {
    const datagram_module = support.datagram;
    const handler = struct {
        fn handle(_: *anyopaque, _: u64, _: []const u8) void {}
    }.handle;

    var router = datagram_module.Router{};
    var context: u8 = 0;
    try router.register("/chat", handler, &context);
    try std.testing.expect(router.find("/chat") != null);
    try std.testing.expect(router.find("/other") == null);
    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        router.register("/chat", handler, &context),
    );
    try std.testing.expectError(
        error.InvalidPath,
        router.register("chat", handler, &context),
    );
}

test "config: app dispatch copies datagrams into the persistent ring" {
    const TestApp = app_module.configured_app_with_timeout(2, 1024, 4096, 0);
    const config = ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_datagram_size = 64,
        .datagram_slots = 4,
        .observability = true,
    };
    var server = try TestApp.init_configured(std.testing.io, std.testing.allocator, config);
    defer server.deinit();

    const State = struct {
        calls: usize = 0,
        session: u64 = 0,
        first: u8 = 0,
    };
    const handler = struct {
        fn handle(context: *anyopaque, session_id: u64, payload: []const u8) void {
            const state: *State = @ptrCast(@alignCast(context));
            state.calls += 1;
            state.session = session_id;
            state.first = if (payload.len > 0) payload[0] else 0;
        }
    }.handle;

    var state = State{};
    _ = try server.datagram_context("/chat", &state, handler);
    try std.testing.expect(server.dispatch_datagram(0, 7, 1, "/chat", "hello"));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(u64, 7), state.session);
    try std.testing.expectEqual(@as(u8, 'h'), state.first);

    const queued = server.next_datagram(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", queued.payload);
    try std.testing.expectEqual(@as(u64, 7), queued.session_id);
    try std.testing.expect(server.next_datagram(0) == null);
    try std.testing.expect(!server.dispatch_datagram(0, 7, 2, "/missing", "x"));

    const registry = server.metrics() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), registry.get(.datagrams_received));

    for (0..4) |index| {
        try std.testing.expect(server.dispatch_datagram(
            0,
            7,
            @intCast(index + 2),
            "/chat",
            "x",
        ));
    }
    try std.testing.expect(!server.dispatch_datagram(0, 7, 99, "/chat", "overflow"));
    try std.testing.expectEqual(@as(u64, 1), registry.get(.datagrams_dropped));
}

test "config: kernel bypass request reports the unwired data path" {
    const TestApp = app_module.configured_app_with_timeout(2, 1024, 4096, 0);
    const config = comptime Preset.kernel_bypass.with(.{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
    });
    var server = try TestApp.init_configured(std.testing.io, std.testing.allocator, config);
    defer server.deinit();

    const registry = server.metrics() orelse return error.TestUnexpectedResult;
    // The server never dispatches through AF_XDP, so it must neither claim the
    // bypass nor leave a transport behind.
    try std.testing.expect(server.xdp_transport == null);
    try std.testing.expectEqual(
        support.xdp_transport.Mode.standard,
        server.transport_availability.mode,
    );
    try std.testing.expectEqual(
        support.xdp_transport.FallbackReason.data_path_unwired,
        server.transport_availability.reason,
    );
    try std.testing.expectEqual(@as(u64, 1), registry.get(.xdp_kernel_bypass_fallbacks));
    try std.testing.expectEqual(@as(u64, 0), registry.get(.kernel_bypass_active));
}

test "config: builder exposes datagram, bypass, and observability knobs" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0)
        .with_webtransport_datagrams(128, 4)
        .with_observability(true)
        .with_metrics_path("/internal/metrics");

    const configuration = builder.configuration();
    try std.testing.expectEqual(@as(usize, 128), configuration.max_datagram_size);
    try std.testing.expectEqual(@as(usize, 4), configuration.datagram_slots);
    try std.testing.expect(configuration.observability);
    try std.testing.expectEqualStrings("/internal/metrics", configuration.metrics_path);

    var server = try builder.build(std.testing.allocator);
    defer server.deinit();
    try std.testing.expect(server.metrics() != null);
    try std.testing.expectEqual(@as(usize, 2), server.datagram_rings.len);
    try std.testing.expectEqual(@as(usize, 2 * 4), server.datagram_session_ids.len);
    try std.testing.expectEqual(@as(usize, 4 * 128), server.datagram_stride);
}

test "config: builder exposes request limit knobs" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0)
        .with_max_request_line_size(12 * 1024)
        .with_max_header_size(24 * 1024)
        .with_max_header_count(128);

    const configuration = builder.configuration();
    try std.testing.expectEqual(@as(usize, 12 * 1024), configuration.max_request_line_size);
    try std.testing.expectEqual(@as(usize, 24 * 1024), configuration.max_header_size);
    try std.testing.expectEqual(@as(usize, 128), configuration.max_header_count);

    var server = try builder.build(std.testing.allocator);
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 12 * 1024), server.max_request_line_size);
    try std.testing.expectEqual(@as(usize, 24 * 1024), server.max_header_size);
    try std.testing.expectEqual(@as(usize, 128), server.max_header_count);
    try std.testing.expectEqual(@as(usize, 64), server.extra_header_capacity);
    try std.testing.expectEqual(
        @as(usize, 2 * server.extra_header_stride),
        server.header_extras.len,
    );
}

test "config: builder accepts HTTP/1 headers above the H3 u16 ceiling" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_idle_timeout_ms(0)
        .with_max_header_size(std.math.maxInt(u16) + 1);

    var server = try builder.build(std.testing.allocator);
    defer server.deinit();
    try std.testing.expectEqual(
        @as(usize, std.math.maxInt(u16) + 1),
        server.max_header_size,
    );
}

test "config: builder exposes HTTP/2 capacity knobs" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0)
        .with_max_h2_header_block_size(12 * 1024)
        .with_max_h2_body_size(20 * 1024)
        .with_max_h2_response_header_size(8 * 1024)
        .with_max_h2_response_header_count(48);

    const configuration = builder.configuration();
    try std.testing.expectEqual(
        @as(usize, 12 * 1024),
        configuration.max_h2_header_block_size,
    );
    try std.testing.expectEqual(@as(usize, 20 * 1024), configuration.max_h2_body_size);
    try std.testing.expectEqual(
        @as(usize, 8 * 1024),
        configuration.max_h2_response_header_size,
    );
    try std.testing.expectEqual(@as(usize, 48), configuration.max_h2_response_header_count);

    var server = try builder.build(std.testing.allocator);
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 12 * 1024), server.h2_capacities.header_block_size);
    try std.testing.expectEqual(@as(usize, 20 * 1024), server.h2_capacities.body_size);
    try std.testing.expectEqual(
        @as(usize, 8 * 1024),
        server.h2_capacities.response_header_size,
    );
    try std.testing.expectEqual(@as(usize, 48), server.h2_capacities.response_header_count);
}

test "config: H3 capacity knobs validate, size, and reach the engine type" {
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(4)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0)
        .with_max_header_size(24 * 1024)
        .with_max_header_count(128)
        .with_max_h3_body_size(20 * 1024)
        .with_max_h3_response_header_size(8 * 1024)
        .with_max_h3_response_header_count(48);

    const configuration = builder.configuration();
    try std.testing.expectEqual(@as(usize, 20 * 1024), configuration.max_h3_body_size);
    try std.testing.expectEqual(@as(usize, 8 * 1024), configuration.max_h3_response_header_size);
    try std.testing.expectEqual(@as(usize, 48), configuration.max_h3_response_header_count);
    try configuration.validate();

    const projection_source = ServerConfig{
        .max_connections = 4,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_header_size = 24 * 1024,
        .max_header_count = 128,
        .max_h3_body_size = 20 * 1024,
        .max_h3_response_header_size = 8 * 1024,
        .max_h3_response_header_count = 48,
    };
    const capacities = comptime projection_source.h3_capacities();
    try std.testing.expectEqual(@as(usize, 24 * 1024), capacities.request_header_size);
    try std.testing.expectEqual(@as(usize, 20 * 1024), capacities.request_body_size);
    try std.testing.expectEqual(@as(usize, 8 * 1024), capacities.response_header_size);
    try std.testing.expectEqual(@as(usize, 48), capacities.response_header_count);
    try std.testing.expectEqual(@as(usize, 128), capacities.decoded_header_count);
    try std.testing.expectEqual(@as(usize, 64), capacities.header_extra_capacity);

    // The engine reserves its storage outside the startup slab, so H3 knobs
    // change the documented engine cost without changing `slab_bytes`.
    const slab_only = configuration.with(.{
        .max_h3_body_size = 16 * 1024,
        .max_h3_response_header_size = 4096,
        .max_h3_response_header_count = 64,
    });
    try std.testing.expectEqual(try slab_only.slab_bytes(), try configuration.slab_bytes());
    try std.testing.expect(
        try configuration.h3_engine_bytes() > try slab_only.h3_engine_bytes(),
    );

    const TestEngine = support.quic_engine.quic_engine(4, 4096, 0, capacities);
    var quic = try TestEngine.init();
    defer quic.deinit();
    try std.testing.expectEqual(@as(usize, 2 * 4 * 24 * 1024), quic.header_storage.len);
    try std.testing.expectEqual(@as(usize, 4 * 20 * 1024), quic.request_body_storage.len);
    try std.testing.expectEqual(@as(usize, 4 * 8 * 1024), quic.response_header_storage.len);
    try std.testing.expectEqual(@as(usize, 4 * 64 * 2), quic.header_extra_storage.len);

    try std.testing.expectError(
        error.InvalidHttp3Capacity,
        (ServerConfig{ .max_h3_body_size = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHttp3Capacity,
        (ServerConfig{ .max_h3_response_header_size = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHttp3Capacity,
        (ServerConfig{ .max_h3_response_header_count = 0 }).validate(),
    );
    // The QUIC stream stacks a transmit descriptor per response field.
    try std.testing.expectError(
        error.InvalidHttp3Capacity,
        (ServerConfig{
            .max_h3_response_header_count = config_module.h3_response_header_count_limit + 1,
        }).validate(),
    );
    try (ServerConfig{
        .max_h3_response_header_count = config_module.h3_response_header_count_limit,
    }).validate();
    // Response field offsets and lengths are u16 in the lsquic header API.
    try std.testing.expectError(
        error.InvalidHttp3Capacity,
        (ServerConfig{ .max_h3_response_header_size = std.math.maxInt(u16) + 1 }).validate(),
    );
    // The shared HTTP/1/2 limit may exceed the lsxpack u16 field-length
    // ceiling; HTTP/3 activation enforces that tighter bound separately.
    try (ServerConfig{ .max_header_size = std.math.maxInt(u16) + 1 }).validate();
    try std.testing.expectError(
        error.SlabSizeOverflow,
        (ServerConfig{ .max_connections = std.math.maxInt(usize) / 2 }).h3_engine_bytes(),
    );
}

test "config: build allocates exactly one slab and routing never allocates" {
    var counting = CountingAllocator{ .parent = std.testing.allocator };
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0);

    var server = try builder.build(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);

    _ = try server.get("/health", dummy_handler);
    _ = try server.post("/echo", dummy_handler);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);

    server.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.frees);
    try std.testing.expectEqual(@as(usize, 0), counting.live_bytes);
}
