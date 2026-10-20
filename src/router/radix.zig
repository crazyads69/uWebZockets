const std = @import("std");
const request_module = @import("../http/request.zig");
const Request = request_module.Request;
const Response = @import("../http/response.zig").Response;
const AsyncResponse = @import("../http/response.zig").AsyncResponse;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const zslay = @import("zslay");
const openapi = @import("../http/openapi.zig");
const radix_pattern = @import("radix_pattern.zig");

/// Existing synchronous route callback ABI.
pub const Handler = *const fn (req: *Request, res: *Response) void;

/// Synchronous callback with a caller-owned context pointer.
pub const ContextHandler = *const fn (context: *anyopaque, req: *Request, res: *Response) void;

/// Deferred callback receiving a copyable, one-shot response token.
pub const AsyncHandler = *const fn (req: *Request, response: AsyncResponse) void;

/// Deferred callback with a caller-owned context pointer.
pub const ContextAsyncHandler = *const fn (
    context: *anyopaque,
    req: *Request,
    response: AsyncResponse,
) void;

/// Synchronous route callback paired with its caller-owned context.
pub const ContextualRoute = struct {
    context: *anyopaque,
    callback: ContextHandler,
};

/// Deferred route callback paired with its caller-owned context.
pub const ContextualAsyncRoute = struct {
    context: *anyopaque,
    callback: ContextAsyncHandler,
};

/// One registered route callback without heap allocation or erased closures.
pub const RouteHandler = union(enum) {
    synchronous: Handler,
    contextual: ContextualRoute,
    asynchronous: AsyncHandler,
    contextual_async: ContextualAsyncRoute,
};

/// Middleware control flow after one ordered callback.
pub const MiddlewareResult = enum(u8) {
    continue_dispatch,
    stop,
};

/// Ordered middleware callback with explicit caller-owned context.
pub const MiddlewareHandler = *const fn (
    context: *anyopaque,
    req: *Request,
    res: *Response,
) MiddlewareResult;

/// Fixed middleware entry stored directly inside the router.
pub const MiddlewareEntry = struct {
    context: *anyopaque,
    callback: MiddlewareHandler,
};

/// WebSocket compression policy for a registered upgrade route.
pub const WsCompression = enum(u8) {
    disabled,
    permessage_deflate,
};

/// Optional authorization callback evaluated before the upgrade response.
pub const WsUpgradeCallback = *const fn (req: *const Request) bool;

/// Called after the protocol upgrade becomes active.
pub const WsOpenCallback = *const fn (ws: *WebSocket) void;

/// Called once for each complete text or binary message.
pub const WsMessageCallback = *const fn (ws: *WebSocket, message: []const u8, opcode: zslay.Opcode) void;

/// Called after write backpressure falls below the connection threshold.
pub const WsDrainCallback = *const fn (ws: *WebSocket) void;

/// Called at most once when the WebSocket closes.
pub const WsCloseCallback = *const fn (ws: *WebSocket) void;

/// Fixed callback set and limits for a WebSocket route.
pub const WsBehavior = struct {
    upgrade: ?WsUpgradeCallback = null,
    open: ?WsOpenCallback = null,
    message: ?WsMessageCallback = null,
    drain: ?WsDrainCallback = null,
    close: ?WsCloseCallback = null,
    /// Negotiates no-context-takeover compression when enabled.
    compression: WsCompression = .disabled,
    /// Maximum encoded payload accepted in one frame.
    max_frame_size: u64 = 16 * 1024,
    /// Maximum decoded payload accepted across a fragmented message.
    max_message_size: u64 = 16 * 1024,
    /// Sends a ping after this many milliseconds without inbound traffic.
    ping_interval_ms: u64 = 0,
    /// Closes a connection when its heartbeat ping remains unanswered.
    pong_timeout_ms: u64 = 0,
};

/// Validates WebSocket limits against the configured connection slab.
pub fn valid_ws_limits(behavior: WsBehavior, message_capacity: usize) bool {
    if (behavior.max_frame_size == 0 or behavior.max_message_size == 0) return false;
    if (behavior.max_frame_size > behavior.max_message_size) return false;
    if ((behavior.ping_interval_ms == 0) != (behavior.pong_timeout_ms == 0)) return false;
    if (behavior.ping_interval_ms > std.math.maxInt(i64)) return false;
    if (behavior.pong_timeout_ms > std.math.maxInt(i64)) return false;
    return behavior.max_message_size <= @as(u64, @intCast(message_capacity));
}

/// HTTP methods supported by the fixed router.
pub const HttpMethod = enum(u8) {
    get,
    head,
    post,
    put,
    delete,
    patch,
    options,
    any,
    query,
    connect,
    trace,

    /// Parses a case-sensitive HTTP method token.
    pub fn parse(value: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, value, "GET")) return .get;
        if (std.mem.eql(u8, value, "HEAD")) return .head;
        if (std.mem.eql(u8, value, "POST")) return .post;
        if (std.mem.eql(u8, value, "PUT")) return .put;
        if (std.mem.eql(u8, value, "DELETE")) return .delete;
        if (std.mem.eql(u8, value, "PATCH")) return .patch;
        if (std.mem.eql(u8, value, "OPTIONS")) return .options;
        if (std.mem.eql(u8, value, "QUERY")) return .query;
        if (std.mem.eql(u8, value, "CONNECT")) return .connect;
        if (std.mem.eql(u8, value, "TRACE")) return .trace;
        return null;
    }

    /// Returns the canonical method spelling, or empty for `any`.
    pub fn name(method: HttpMethod) []const u8 {
        return switch (method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
            .options => "OPTIONS",
            .any => "",
            .query => "QUERY",
            .connect => "CONNECT",
            .trace => "TRACE",
        };
    }

    /// Reports whether HTTP/1.1 TLS 0-RTT may dispatch this method.
    pub fn early_data_safe(method: HttpMethod) bool {
        return switch (method) {
            .get, .head, .options, .trace => true,
            else => false,
        };
    }
};

fn lower_method(method: HttpMethod) []const u8 {
    return switch (method) {
        .get => "get",
        .head => "head",
        .post => "post",
        .put => "put",
        .delete => "delete",
        .patch => "patch",
        .options => "options",
        .query => "x-query",
        .connect => "x-connect",
        .trace => "trace",
        .any => "x-any",
    };
}

const method_count = @typeInfo(HttpMethod).@"enum".fields.len;
const concrete_methods = [_]HttpMethod{ .get, .head, .post, .put, .delete, .patch, .options, .trace, .query };
const all_method_mask: u16 = ((@as(u16, 1) << method_count) - 1) &
    ~(@as(u16, 1) << @intFromEnum(HttpMethod.any));

/// Result of exact or parameterized route selection.
pub const RouteMatch = struct {
    /// Borrowed request path used for this lookup.
    path: []const u8,
    /// Selected callback for the requested method, when registered.
    handler: ?RouteHandler,
    /// Legacy synchronous callback when `handler` is synchronous.
    http_handler: ?Handler,
    /// WebSocket behavior registered on this path, when present.
    ws_behavior: ?WsBehavior,
    /// Bit mask used to format the HTTP Allow response field.
    allowed_methods: u16,
    /// Reports whether any HTTP method is registered on this path.
    has_http: bool,
};

/// Default maximum number of radix nodes per router.
pub const default_max_nodes = 256;
/// Default maximum number of parameterized route patterns.
pub const default_max_pattern_routes = 64;
/// Default maximum number of ordered global middleware callbacks.
pub const default_max_middleware = 32;
/// Compatibility alias for the default middleware capacity.
pub const max_middleware = default_max_middleware;
/// Compatibility alias for the default pattern-route capacity.
pub const max_pattern_routes = default_max_pattern_routes;

const null_node: u16 = std.math.maxInt(u16);
const empty_handlers = [_]?RouteHandler{null} ** method_count;
/// Smallest static-route index size; keeps tiny capacity sets probeable.
const min_static_index_size: usize = 16;

/// FNV-1a 64-bit hash of one route path.
///
/// The static-route index uses it to pick the first probe slot; slots are
/// still accepted only after a byte comparison, so the hash only affects
/// probe length.
pub fn hash_path(path: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (path) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Parameterized route pattern with its per-method callbacks.
pub const PatternRoute = struct {
    handlers: [method_count]?RouteHandler = empty_handlers,
    ws_behavior: ?WsBehavior = null,
    static_bytes: u16 = 0,
    parameter_count: u8 = 0,
    has_wildcard: bool = false,
};

/// One route retained for introspection.
pub const RouteRecord = struct {
    // u32 keeps the 64 KiB registry representable; u16 overflowed at 65536.
    offset: u32,
    length: u16,
    method: HttpMethod,
    websocket: bool,
};

/// Capacity configuration for one router instance.
pub const Capacities = struct {
    /// Maximum radix nodes, one per stored path segment.
    max_nodes: usize = default_max_nodes,
    /// Maximum parameterized route patterns.
    max_pattern_routes: usize = default_max_pattern_routes,
    /// Maximum ordered global middleware callbacks.
    max_middleware: usize = default_max_middleware,
    /// Maximum accepted route path length in bytes.
    max_route_path_size: usize = radix_pattern.max_route_path_size,
    /// Maximum route captures accepted on one request.
    max_route_params: usize = request_module.max_route_params,
    /// Bytes retained for the route paths kept for introspection.
    registry_storage_size: usize = 64 * 1024,

    /// Total bytes required for `carve_storage`, with every sub-array aligned.
    pub fn storage_bytes(self: Capacities) error{InvalidRouterCapacity}!usize {
        return (try plan_storage(self)).total;
    }

    /// Number of route records retained for introspection.
    pub fn max_registered_routes(self: Capacities) usize {
        return self.max_nodes + self.max_pattern_routes;
    }
};

/// Borrowed typed storage for one router instance.
///
/// `carve_storage` and `Bundle.storage` produce aligned, non-overlapping
/// slices; the router borrows them for its whole lifetime.
pub const Storage = struct {
    /// Route path bytes for node segments and parameterized patterns.
    route_storage: []u8,
    /// Largest accepted route path length for this router.
    max_route_path_size: usize,
    /// Maximum route captures accepted by this router's patterns.
    max_route_params: usize,
    /// Offset of each node's segment inside `route_storage`.
    segment_offsets: []u32,
    /// Byte length of each node's segment.
    segment_lengths: []u16,
    /// First child node index per node; `null_node` marks none.
    first_child: []u16,
    /// Next sibling node index per node; `null_node` marks none.
    next_sibling: []u16,
    /// Whether a node terminates at least one registered route.
    has_route: []bool,
    /// Per-node HTTP method callbacks.
    http_handlers: [][method_count]?RouteHandler,
    /// Per-node WebSocket behavior.
    ws_behaviors: []?WsBehavior,
    /// Parameterized route patterns.
    pattern_routes: []PatternRoute,
    /// Offset of each pattern path inside `route_storage`.
    pattern_offsets: []u32,
    /// Byte length of each pattern path.
    pattern_lengths: []u16,
    /// Ordered global middleware entries.
    middleware: []MiddlewareEntry,
    /// Route paths retained for introspection.
    registry_storage: []u8,
    /// Route records indexing into `registry_storage`.
    route_records: []RouteRecord,
    /// Parent node per radix node; `null_node` marks the root.
    parents: []u16,
    /// Static-route index slot node indices; `null_node` marks an empty slot.
    static_nodes: []u16,
    /// Static-route index slot hashes; parallel to `static_nodes`.
    static_hashes: []u64,
};

/// Alignment every carved region base must satisfy for `storage_bytes` to be
/// the exact consumed size.
pub const storage_alignment = @alignOf(Storage);

/// Aligned byte span inside a carved router region.
const Span = struct {
    start: usize,
    end: usize,
};

/// Byte span of every carved sub-array plus the total region size.
const StoragePlan = struct {
    route_storage: Span,
    segment_offsets: Span,
    segment_lengths: Span,
    first_child: Span,
    next_sibling: Span,
    has_route: Span,
    http_handlers: Span,
    ws_behaviors: Span,
    pattern_routes: Span,
    pattern_offsets: Span,
    pattern_lengths: Span,
    middleware: Span,
    registry_storage: Span,
    route_records: Span,
    parents: Span,
    static_nodes: Span,
    static_hashes: Span,
    total: usize,
};

/// Validates one capacity set; every rejection marks a configuration the
/// router cannot represent or use.
fn validate_capacities(capacities: Capacities) error{InvalidRouterCapacity}!void {
    if (capacities.max_nodes == 0) return error.InvalidRouterCapacity;
    if (capacities.max_nodes > std.math.maxInt(u16)) return error.InvalidRouterCapacity;
    if (capacities.max_pattern_routes > std.math.maxInt(u8)) return error.InvalidRouterCapacity;
    if (capacities.max_middleware > std.math.maxInt(u8)) return error.InvalidRouterCapacity;
    if (capacities.max_route_path_size == 0) return error.InvalidRouterCapacity;
    if (capacities.max_route_path_size > std.math.maxInt(u16)) return error.InvalidRouterCapacity;
    // The registry must hold at least one maximum-length route path.
    if (capacities.registry_storage_size < capacities.max_route_path_size) {
        return error.InvalidRouterCapacity;
    }
    if (capacities.registry_storage_size > std.math.maxInt(u32)) {
        return error.InvalidRouterCapacity;
    }
    const record_count = std.math.add(
        usize,
        capacities.max_nodes,
        capacities.max_pattern_routes,
    ) catch return error.InvalidRouterCapacity;
    if (record_count > std.math.maxInt(u16)) return error.InvalidRouterCapacity;
    const route_bytes = std.math.mul(
        usize,
        record_count,
        capacities.max_route_path_size,
    ) catch return error.InvalidRouterCapacity;
    if (route_bytes > std.math.maxInt(u32)) return error.InvalidRouterCapacity;
}

/// Reserves `count` elements in a carved region; `element_bytes` is explicit
/// so untyped byte ranges share the same checked arithmetic.
fn reserve(
    cursor: *usize,
    count: usize,
    element_bytes: usize,
    alignment: usize,
) error{InvalidRouterCapacity}!Span {
    const bytes = std.math.mul(usize, count, element_bytes) catch {
        return error.InvalidRouterCapacity;
    };
    const remainder = cursor.* % alignment;
    const padding = if (remainder == 0) 0 else alignment - remainder;
    const start = std.math.add(usize, cursor.*, padding) catch {
        return error.InvalidRouterCapacity;
    };
    const end = std.math.add(usize, start, bytes) catch return error.InvalidRouterCapacity;
    cursor.* = end;
    return .{ .start = start, .end = end };
}

/// Static-route index size: the next power of two at or above twice
/// `max_nodes`, floored at `min_static_index_size`.
///
/// Bounding the load factor at one half keeps every probe chain short and
/// guarantees an insertion or lookup reaches an empty slot.
fn static_index_size_for(max_nodes: usize) error{InvalidRouterCapacity}!usize {
    const doubled = std.math.mul(usize, max_nodes, 2) catch return error.InvalidRouterCapacity;
    const rounded = std.math.ceilPowerOfTwo(usize, doubled) catch {
        return error.InvalidRouterCapacity;
    };
    return @max(rounded, min_static_index_size);
}

/// Plans the exact carve layout; `storage_bytes` and `carve_storage` both use
/// this plan so region size and offsets cannot drift.
fn plan_storage(capacities: Capacities) error{InvalidRouterCapacity}!StoragePlan {
    try validate_capacities(capacities);
    const record_count = capacities.max_registered_routes();
    const static_index_size = try static_index_size_for(capacities.max_nodes);

    var cursor: usize = 0;
    var plan: StoragePlan = undefined;
    plan.route_storage = try reserve(&cursor, record_count, capacities.max_route_path_size, 1);
    plan.segment_offsets = try reserve(&cursor, capacities.max_nodes, @sizeOf(u32), @alignOf(u32));
    plan.segment_lengths = try reserve(&cursor, capacities.max_nodes, @sizeOf(u16), @alignOf(u16));
    plan.first_child = try reserve(&cursor, capacities.max_nodes, @sizeOf(u16), @alignOf(u16));
    plan.next_sibling = try reserve(&cursor, capacities.max_nodes, @sizeOf(u16), @alignOf(u16));
    plan.has_route = try reserve(&cursor, capacities.max_nodes, @sizeOf(bool), @alignOf(bool));
    plan.http_handlers = try reserve(
        &cursor,
        capacities.max_nodes,
        @sizeOf([method_count]?RouteHandler),
        @alignOf([method_count]?RouteHandler),
    );
    plan.ws_behaviors = try reserve(
        &cursor,
        capacities.max_nodes,
        @sizeOf(?WsBehavior),
        @alignOf(?WsBehavior),
    );
    plan.pattern_routes = try reserve(
        &cursor,
        capacities.max_pattern_routes,
        @sizeOf(PatternRoute),
        @alignOf(PatternRoute),
    );
    plan.pattern_offsets = try reserve(
        &cursor,
        capacities.max_pattern_routes,
        @sizeOf(u32),
        @alignOf(u32),
    );
    plan.pattern_lengths = try reserve(
        &cursor,
        capacities.max_pattern_routes,
        @sizeOf(u16),
        @alignOf(u16),
    );
    plan.middleware = try reserve(
        &cursor,
        capacities.max_middleware,
        @sizeOf(MiddlewareEntry),
        @alignOf(MiddlewareEntry),
    );
    plan.registry_storage = try reserve(&cursor, capacities.registry_storage_size, 1, 1);
    plan.route_records = try reserve(
        &cursor,
        record_count,
        @sizeOf(RouteRecord),
        @alignOf(RouteRecord),
    );
    // Parents and node slots first; the hash array closes the plan on an
    // eight-aligned boundary so `storage_bytes` is a multiple of the storage
    // alignment and an exactly sized region carves without trailing waste.
    plan.parents = try reserve(
        &cursor,
        capacities.max_nodes,
        @sizeOf(u16),
        @alignOf(u16),
    );
    plan.static_nodes = try reserve(
        &cursor,
        static_index_size,
        @sizeOf(u16),
        @alignOf(u16),
    );
    plan.static_hashes = try reserve(
        &cursor,
        static_index_size,
        @sizeOf(u64),
        @alignOf(u64),
    );
    plan.total = cursor;
    return plan;
}

/// Re-tags one planned byte span; `carve_storage` proved the pointer aligned.
fn carved_slice(comptime T: type, region: []u8, prefix: usize, span: Span) []T {
    const bytes = region[prefix + span.start .. prefix + span.end];
    const aligned = @as([*]align(@alignOf(T)) u8, @alignCast(bytes.ptr));
    const pointer: [*]T = @ptrCast(aligned);
    return pointer[0 .. bytes.len / @sizeOf(T)];
}

/// Carves `region` into typed, aligned slices for `capacities`.
///
/// The carved layout consumes exactly `storage_bytes` bytes from the first
/// address in `region` that satisfies `storage_alignment`; a misaligned base
/// therefore needs up to `storage_alignment - 1` extra bytes.
pub fn carve_storage(region: []u8, capacities: Capacities) error{InvalidRouterCapacity}!Storage {
    const plan = try plan_storage(capacities);
    const base = @intFromPtr(region.ptr);
    const padded = std.math.add(usize, base, storage_alignment - 1) catch {
        return error.InvalidRouterCapacity;
    };
    const start = padded - (padded % storage_alignment);
    const prefix = start - base;
    if (prefix > region.len) return error.InvalidRouterCapacity;
    if (plan.total > region.len - prefix) return error.InvalidRouterCapacity;

    return .{
        .route_storage = carved_slice(u8, region, prefix, plan.route_storage),
        .max_route_path_size = capacities.max_route_path_size,
        .max_route_params = capacities.max_route_params,
        .segment_offsets = carved_slice(u32, region, prefix, plan.segment_offsets),
        .segment_lengths = carved_slice(u16, region, prefix, plan.segment_lengths),
        .first_child = carved_slice(u16, region, prefix, plan.first_child),
        .next_sibling = carved_slice(u16, region, prefix, plan.next_sibling),
        .has_route = carved_slice(bool, region, prefix, plan.has_route),
        .http_handlers = carved_slice(
            [method_count]?RouteHandler,
            region,
            prefix,
            plan.http_handlers,
        ),
        .ws_behaviors = carved_slice(?WsBehavior, region, prefix, plan.ws_behaviors),
        .pattern_routes = carved_slice(PatternRoute, region, prefix, plan.pattern_routes),
        .pattern_offsets = carved_slice(u32, region, prefix, plan.pattern_offsets),
        .pattern_lengths = carved_slice(u16, region, prefix, plan.pattern_lengths),
        .middleware = carved_slice(MiddlewareEntry, region, prefix, plan.middleware),
        .registry_storage = carved_slice(u8, region, prefix, plan.registry_storage),
        .route_records = carved_slice(RouteRecord, region, prefix, plan.route_records),
        .parents = carved_slice(u16, region, prefix, plan.parents),
        .static_nodes = carved_slice(u16, region, prefix, plan.static_nodes),
        .static_hashes = carved_slice(u64, region, prefix, plan.static_hashes),
    };
}

/// Inline storage for tests and stack callers; `storage()` yields the slices.
/// Alias kept for the PascalCase public spelling.
pub const Bundle = bundle;
/// Inline storage for tests and stack callers; `storage()` yields the slices.
pub fn bundle(comptime capacities: Capacities) type {
    comptime {
        _ = capacities.storage_bytes() catch @compileError("invalid router capacities");
    }
    return struct {
        const Self = @This();
        // The guard above proved the capacities valid, so the plan cannot fail.
        const bytes_len = capacities.storage_bytes() catch unreachable;

        bytes: [bytes_len]u8 align(storage_alignment) = undefined,

        /// Borrows the bundle's inline region as router storage.
        pub fn storage(self: *Self) Storage {
            // The region is aligned and exactly `storage_bytes` long, so the
            // carve cannot fail for these capacities.
            return carve_storage(&self.bytes, capacities) catch unreachable;
        }
    };
}

/// Default router capacity configuration.
pub const default_capacities = Capacities{};
/// Inline default-capacity bundle.
pub const DefaultBundle = Bundle(default_capacities);

/// Allocation-free radix router over caller-provided storage.
pub const Router = struct {
    route_storage: []u8 = &.{},
    /// Largest accepted route path length, copied from `Storage`.
    max_route_path_size: usize = radix_pattern.max_route_path_size,
    /// Maximum route captures accepted by patterns, copied from `Storage`.
    max_route_params: usize = request_module.max_route_params,
    segment_offsets: []u32 = &.{},
    segment_lengths: []u16 = &.{},
    first_child: []u16 = &.{},
    next_sibling: []u16 = &.{},
    has_route: []bool = &.{},
    http_handlers: [][method_count]?RouteHandler = &.{},
    ws_behaviors: []?WsBehavior = &.{},
    pattern_routes: []PatternRoute = &.{},
    pattern_offsets: []u32 = &.{},
    pattern_lengths: []u16 = &.{},
    middleware: []MiddlewareEntry = &.{},
    registry_storage: []u8 = &.{},
    route_records: []RouteRecord = &.{},
    static_hashes: []u64 = &.{},
    static_nodes: []u16 = &.{},
    parents: []u16 = &.{},

    node_count: u16 = 0,
    root_idx: u16 = null_node,
    pattern_count: u8 = 0,
    middleware_count: u8 = 0,
    route_storage_length: u32 = 0,
    registry_storage_length: u32 = 0,
    route_record_count: u16 = 0,

    /// Binds `storage` and initializes the root node.
    pub fn init(storage: Storage) error{InvalidRouterCapacity}!Router {
        try validate_capacities(.{
            .max_nodes = storage.segment_offsets.len,
            .max_pattern_routes = storage.pattern_routes.len,
            .max_middleware = storage.middleware.len,
            .max_route_path_size = storage.max_route_path_size,
            .max_route_params = storage.max_route_params,
            .registry_storage_size = storage.registry_storage.len,
        });

        var router = Router{
            .route_storage = storage.route_storage,
            .max_route_path_size = storage.max_route_path_size,
            .max_route_params = storage.max_route_params,
            .segment_offsets = storage.segment_offsets,
            .segment_lengths = storage.segment_lengths,
            .first_child = storage.first_child,
            .next_sibling = storage.next_sibling,
            .has_route = storage.has_route,
            .http_handlers = storage.http_handlers,
            .ws_behaviors = storage.ws_behaviors,
            .pattern_routes = storage.pattern_routes,
            .pattern_offsets = storage.pattern_offsets,
            .pattern_lengths = storage.pattern_lengths,
            .middleware = storage.middleware,
            .registry_storage = storage.registry_storage,
            .route_records = storage.route_records,
            .static_hashes = storage.static_hashes,
            .static_nodes = storage.static_nodes,
            .parents = storage.parents,
        };
        router.root_idx = 0;
        router.node_count = 1;
        router.segment_offsets[0] = 0;
        router.segment_lengths[0] = 0;
        router.first_child[0] = null_node;
        router.next_sibling[0] = null_node;
        router.has_route[0] = false;
        router.http_handlers[0] = empty_handlers;
        router.ws_behaviors[0] = null;
        router.parents[0] = null_node;
        @memset(router.static_nodes, null_node);
        return router;
    }

    fn alloc_node(self: *Router, bytes: []const u8, parent: u16) !u16 {
        if (@as(usize, self.node_count) >= self.segment_offsets.len) {
            return error.RouteCapacityReached;
        }
        if (bytes.len > self.max_route_path_size) return error.InvalidRoutePath;

        const index = self.node_count;
        self.segment_offsets[index] = try self.store_path(bytes);
        self.segment_lengths[index] = @intCast(bytes.len);
        self.node_count += 1;
        self.first_child[index] = null_node;
        self.next_sibling[index] = null_node;
        self.parents[index] = parent;
        self.has_route[index] = false;
        self.http_handlers[index] = empty_handlers;
        self.ws_behaviors[index] = null;
        return index;
    }

    fn store_path(self: *Router, path: []const u8) !u32 {
        const start: usize = @intCast(self.route_storage_length);
        if (path.len > self.route_storage.len - start) return error.RouteStorageCapacityReached;
        const end = start + path.len;
        @memcpy(self.route_storage[start..end], path);
        self.route_storage_length = @intCast(end);
        return @intCast(start);
    }

    fn segment(self: *const Router, index: u16) []const u8 {
        const start: usize = @intCast(self.segment_offsets[index]);
        const length: usize = self.segment_lengths[index];
        return self.route_storage[start .. start + length];
    }

    fn pattern_path(self: *const Router, index: u8) []const u8 {
        const start: usize = @intCast(self.pattern_offsets[index]);
        const length: usize = self.pattern_lengths[index];
        return self.route_storage[start .. start + length];
    }

    fn common_prefix(first: []const u8, second: []const u8) usize {
        const length = @min(first.len, second.len);
        var index: usize = 0;
        while (index < length and first[index] == second[index]) : (index += 1) {}
        return index;
    }

    fn insert_path(self: *Router, path: []const u8) !u16 {
        if (!radix_pattern.valid_path(path, self.max_route_path_size)) {
            return error.InvalidRoutePath;
        }

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return current;

            var best_child: u16 = null_node;
            var best_prefix: usize = 0;
            var child = self.first_child[current];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const prefix = common_prefix(self.segment(child), search);
                if (prefix == 0) continue;
                best_child = child;
                best_prefix = prefix;
                break;
            }

            if (best_child == null_node) {
                const new_child = try self.alloc_node(search, current);
                self.next_sibling[new_child] = self.first_child[current];
                self.first_child[current] = new_child;
                return new_child;
            }

            const child_segment = self.segment(best_child);
            if (best_prefix < child_segment.len) {
                const required_nodes: usize = if (best_prefix < search.len) 2 else 1;
                const nodes_left = self.segment_offsets.len - @as(usize, self.node_count);
                if (required_nodes > nodes_left) return error.RouteCapacityReached;

                const split_node = try self.alloc_node(child_segment[best_prefix..], best_child);
                self.first_child[split_node] = self.first_child[best_child];
                self.has_route[split_node] = self.has_route[best_child];
                self.http_handlers[split_node] = self.http_handlers[best_child];
                self.ws_behaviors[split_node] = self.ws_behaviors[best_child];
                if (self.has_route[split_node]) self.relocate_static_index(best_child, split_node);

                self.segment_lengths[best_child] = @intCast(best_prefix);
                self.first_child[best_child] = split_node;
                self.has_route[best_child] = false;
                self.http_handlers[best_child] = empty_handlers;
                self.ws_behaviors[best_child] = null;
            }

            if (best_prefix == search.len) return best_child;
            current = best_child;
            search = search[best_prefix..];
        }
    }

    fn register_http(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        return self.register_route(path, method, .{ .synchronous = handler });
    }

    fn register_route(
        self: *Router,
        path: []const u8,
        method: HttpMethod,
        handler: RouteHandler,
    ) !void {
        try self.ensure_route_record(path);
        const pattern = try radix_pattern.analyze_pattern(
            path,
            self.max_route_path_size,
            self.max_route_params,
        );
        if (pattern.dynamic) {
            const route = try self.get_or_add_pattern(path, pattern);
            const method_index = @intFromEnum(method);
            if (route.handlers[method_index] != null) return error.RouteAlreadyRegistered;
            route.handlers[method_index] = handler;
            self.record_route(path, method, false);
            return;
        }

        const node = try self.insert_path(path);
        const method_index = @intFromEnum(method);
        if (self.http_handlers[node][method_index] != null) return error.RouteAlreadyRegistered;

        self.http_handlers[node][method_index] = handler;
        self.has_route[node] = true;
        self.index_static_path(path, node);
        self.record_route(path, method, false);
    }

    /// Registers a synchronous GET route.
    pub fn get(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .get, handler);
    }

    /// Registers a synchronous HEAD route.
    pub fn head(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .head, handler);
    }

    /// Registers a synchronous POST route.
    pub fn post(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .post, handler);
    }

    /// Registers a synchronous PUT route.
    pub fn put(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .put, handler);
    }

    /// Registers a synchronous DELETE route.
    pub fn delete(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .delete, handler);
    }

    /// Registers a synchronous PATCH route.
    pub fn patch(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .patch, handler);
    }

    /// Registers a synchronous OPTIONS route.
    pub fn options(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .options, handler);
    }

    /// Registers a safe, idempotent RFC 10008 QUERY route.
    pub fn query(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .query, handler);
    }

    /// Registers an opt-in TRACE route.
    pub fn trace(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .trace, handler);
    }

    /// Registers a synchronous fallback method route.
    pub fn any(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .any, handler);
    }

    /// Registers a context-aware route for one method.
    pub fn route_context(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        context: *anyopaque,
        handler: ContextHandler,
    ) !void {
        return self.register_route(path, method, .{ .contextual = .{
            .context = context,
            .callback = handler,
        } });
    }

    /// Registers a deferred route for one method.
    pub fn route_async(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        handler: AsyncHandler,
    ) !void {
        return self.register_route(path, method, .{ .asynchronous = handler });
    }

    /// Registers a context-aware deferred route for one method.
    pub fn route_async_context(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        context: *anyopaque,
        handler: ContextAsyncHandler,
    ) !void {
        return self.register_route(path, method, .{ .contextual_async = .{
            .context = context,
            .callback = handler,
        } });
    }

    /// Appends one global middleware callback in execution order.
    pub fn use(
        self: *Router,
        context: *anyopaque,
        callback: MiddlewareHandler,
    ) !void {
        if (@as(usize, self.middleware_count) == self.middleware.len) {
            return error.MiddlewareCapacityReached;
        }
        self.middleware[self.middleware_count] = .{
            .context = context,
            .callback = callback,
        };
        self.middleware_count += 1;
    }

    /// Executes middleware until a callback or response stops dispatch.
    pub fn run_middleware(
        self: *const Router,
        request: *Request,
        response: *Response,
    ) MiddlewareResult {
        for (self.middleware[0..self.middleware_count]) |entry| {
            const result = entry.callback(entry.context, request, response);
            if (result == .stop or response.is_started()) return .stop;
        }
        return .continue_dispatch;
    }

    /// Registers a WebSocket upgrade route.
    pub fn ws(self: *Router, path: []const u8, behavior: WsBehavior) !void {
        try self.ensure_route_record(path);
        const pattern = try radix_pattern.analyze_pattern(
            path,
            self.max_route_path_size,
            self.max_route_params,
        );
        if (pattern.dynamic) {
            const route = try self.get_or_add_pattern(path, pattern);
            if (route.ws_behavior != null) return error.RouteAlreadyRegistered;
            route.ws_behavior = behavior;
            self.record_route(path, .get, true);
            return;
        }

        const node = try self.insert_path(path);
        if (self.ws_behaviors[node] != null) return error.RouteAlreadyRegistered;

        self.ws_behaviors[node] = behavior;
        self.has_route[node] = true;
        self.index_static_path(path, node);
        self.record_route(path, .get, true);
    }

    /// Writes OpenAPI 3.1 JSON for all successfully registered routes.
    ///
    /// The document is generated into the tail of `buffer`; the leading bytes
    /// hold the bounded route snapshot and are not part of the result. Returns
    /// `error.BufferTooSmall` when `buffer` cannot hold both.
    pub fn write_openapi(
        self: *const Router,
        buffer: []u8,
        spec_options: openapi.Options,
    ) ![]const u8 {
        const record_count: usize = self.route_record_count;
        const snapshot_bytes = std.math.mul(
            usize,
            record_count,
            @sizeOf(openapi.Route),
        ) catch return error.BufferTooSmall;
        const base = @intFromPtr(buffer.ptr);
        const padded = std.math.add(usize, base, @alignOf(openapi.Route) - 1) catch {
            return error.BufferTooSmall;
        };
        const snapshot_start = padded - (padded % @alignOf(openapi.Route)) - base;
        if (snapshot_start > buffer.len or snapshot_bytes > buffer.len - snapshot_start) {
            return error.BufferTooSmall;
        }

        const snapshot_region = buffer[snapshot_start .. snapshot_start + snapshot_bytes];
        const aligned = @as(
            [*]align(@alignOf(openapi.Route)) u8,
            @alignCast(snapshot_region.ptr),
        );
        const snapshot: []openapi.Route = @as(
            [*]openapi.Route,
            @ptrCast(aligned),
        )[0..record_count];
        for (self.route_records[0..record_count], snapshot) |record, *route| {
            route.* = self.openapi_route(record);
        }
        return openapi.generate(
            buffer[snapshot_start + snapshot_bytes ..],
            snapshot,
            spec_options,
        );
    }

    fn openapi_route(self: *const Router, record: RouteRecord) openapi.Route {
        const start: usize = record.offset;
        return .{
            .method = if (record.method == .any) "x-any" else lower_method(record.method),
            .path = self.registry_storage[start .. start + record.length],
            .websocket = record.websocket,
        };
    }

    fn ensure_route_record(self: *const Router, path: []const u8) !void {
        if (@as(usize, self.route_record_count) == self.route_records.len) {
            return error.RouteCapacityReached;
        }
        if (path.len > self.max_route_path_size) return error.InvalidRoutePath;
        const written: usize = self.registry_storage_length;
        if (path.len > self.registry_storage.len - written) {
            return error.RouteStorageCapacityReached;
        }
    }

    fn record_route(self: *Router, path: []const u8, method: HttpMethod, websocket: bool) void {
        const start = self.registry_storage_length;
        @memcpy(self.registry_storage[start..][0..path.len], path);
        self.registry_storage_length += @intCast(path.len);
        self.route_records[self.route_record_count] = .{
            .offset = start,
            .length = @intCast(path.len),
            .method = method,
            .websocket = websocket,
        };
        self.route_record_count += 1;
    }

    /// Reports whether the stored segments from `node` up to the root
    /// concatenate to exactly `path`.
    fn node_path_equals(self: *const Router, node: u16, path: []const u8) bool {
        var remaining = path;
        var current = node;
        while (true) {
            if (current == self.root_idx) return remaining.len == 0;
            const bytes = self.segment(current);
            if (bytes.len > remaining.len) return false;
            const start = remaining.len - bytes.len;
            if (!std.mem.eql(u8, remaining[start..], bytes)) return false;
            remaining = remaining[0..start];
            current = self.parents[current];
        }
    }

    /// Probes the static-route index for the terminal node registered under
    /// `path`.
    ///
    /// A slot is accepted only when its hash and the node's stored segments
    /// both match, so a hash collision falls through to the next probe
    /// instead of selecting the wrong route.
    fn find_static_node(self: *const Router, path: []const u8) ?u16 {
        if (self.static_nodes.len == 0) return null;

        const hash = hash_path(path);
        const mask = self.static_nodes.len - 1;
        var index = @as(usize, @truncate(hash)) & mask;
        while (true) {
            const node = self.static_nodes[index];
            if (node == null_node) return null;
            if (self.static_hashes[index] == hash and self.node_path_equals(node, path)) {
                return node;
            }
            index = (index + 1) & mask;
        }
    }

    /// Adds `node` to the static-route index under its full `path`.
    ///
    /// Re-registering the same path for another method probes the existing
    /// slot and leaves the table unchanged, keeping one entry per route.
    fn index_static_path(self: *Router, path: []const u8, node: u16) void {
        const hash = hash_path(path);
        const mask = self.static_nodes.len - 1;
        var index = @as(usize, @truncate(hash)) & mask;
        // At most `max_nodes` terminal routes are indexed and the table is at
        // least twice that size, so the probe always reaches an empty slot.
        while (true) {
            const slot = self.static_nodes[index];
            if (slot == null_node) {
                self.static_hashes[index] = hash;
                self.static_nodes[index] = node;
                return;
            }
            if (self.static_hashes[index] == hash and self.node_path_equals(slot, path)) return;
            index = (index + 1) & mask;
        }
    }

    /// Re-points the index entry of a node that a split just superseded.
    ///
    /// Splitting truncates `from` and moves its route to `to`; without the
    /// update the index would keep resolving the now-route-less node.
    fn relocate_static_index(self: *Router, from: u16, to: u16) void {
        for (self.static_nodes) |*slot| {
            if (slot.* == from) {
                slot.* = to;
                return;
            }
        }
    }

    /// Reports whether any route enables automatic WebSocket heartbeats.
    pub fn has_ws_heartbeats(self: *const Router) bool {
        for (self.ws_behaviors[0..self.node_count]) |behavior| {
            if (behavior) |configured| {
                if (configured.ping_interval_ms != 0) return true;
            }
        }
        for (self.pattern_routes[0..self.pattern_count]) |route| {
            if (route.ws_behavior) |configured| {
                if (configured.ping_interval_ms != 0) return true;
            }
        }
        return false;
    }

    /// Matches a path without materializing parameter captures.
    pub fn match(self: *const Router, path: []const u8, method: ?HttpMethod) ?RouteMatch {
        if (self.find_static_node(path)) |node| return self.node_match(node, path, method);
        if (self.find_node(path)) |node| return self.node_match(node, path, method);
        const pattern_index = self.find_pattern(path) orelse return null;
        return self.pattern_match(pattern_index, path, method);
    }

    /// Matches a request and stores borrowed route captures in its fixed array.
    pub fn match_request(
        self: *const Router,
        request: *Request,
        method: ?HttpMethod,
    ) ?RouteMatch {
        request.clear_params();
        if (self.find_static_node(request.path)) |node| {
            return self.node_match(node, request.path, method);
        }
        if (self.find_node(request.path)) |node| {
            return self.node_match(node, request.path, method);
        }

        const pattern_index = self.find_pattern(request.path) orelse return null;
        capture_pattern(
            self.pattern_path(pattern_index),
            request.path,
            request,
        ) catch return null;
        return self.pattern_match(pattern_index, request.path, method);
    }

    fn find_node(self: *const Router, path: []const u8) ?u16 {
        if (self.node_count == 0) return null;

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return if (self.has_route[current]) current else null;

            var child = self.first_child[current];
            var found = false;
            const first_char = search[0];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const child_segment = self.segment(child);
                if (child_segment.len == 0 or child_segment[0] != first_char) continue;
                if (!std.mem.startsWith(u8, search, child_segment)) return null;

                current = child;
                search = search[child_segment.len..];
                found = true;
                break;
            }

            if (!found) return null;
        }
    }

    fn node_has_http(self: *const Router, node: u16) bool {
        for (self.http_handlers[node]) |handler| {
            if (handler != null) return true;
        }
        return false;
    }

    fn node_match(
        self: *const Router,
        node: u16,
        path: []const u8,
        method: ?HttpMethod,
    ) RouteMatch {
        const handler = select_handler(&self.http_handlers[node], method);
        return .{
            .path = path,
            .handler = handler,
            .http_handler = legacy_handler(handler),
            .ws_behavior = self.ws_behaviors[node],
            .allowed_methods = self.allowed_method_mask(node),
            .has_http = self.node_has_http(node),
        };
    }

    fn pattern_match(
        self: *const Router,
        pattern_index: u8,
        path: []const u8,
        method: ?HttpMethod,
    ) RouteMatch {
        const route = self.pattern_routes[pattern_index];
        const handler = select_handler(&route.handlers, method);
        return .{
            .path = path,
            .handler = handler,
            .http_handler = legacy_handler(handler),
            .ws_behavior = route.ws_behavior,
            .allowed_methods = allowed_handler_mask(&route.handlers, route.ws_behavior != null),
            .has_http = handlers_present(&route.handlers),
        };
    }

    /// Returns the pattern route for `path`, rejecting a shape that differs
    /// only in capture names so no registered route is silently shadowed.
    fn get_or_add_pattern(
        self: *Router,
        path: []const u8,
        info: radix_pattern.PatternInfo,
    ) !*PatternRoute {
        for (0..self.pattern_count) |index| {
            const existing_path = self.pattern_path(@intCast(index));
            if (std.mem.eql(u8, existing_path, path)) return &self.pattern_routes[index];

            const existing = self.pattern_routes[index];
            if (info.static_bytes == existing.static_bytes and
                info.has_wildcard == existing.has_wildcard and
                info.parameter_count == existing.parameter_count and
                same_pattern_skeleton(existing_path, path))
            {
                return error.RoutePatternConflicts;
            }
        }
        if (@as(usize, self.pattern_count) == self.pattern_routes.len) {
            return error.RouteCapacityReached;
        }

        const index = self.pattern_count;
        self.pattern_offsets[index] = try self.store_path(path);
        self.pattern_lengths[index] = @intCast(path.len);
        self.pattern_count += 1;
        self.pattern_routes[index] = .{
            .static_bytes = info.static_bytes,
            .parameter_count = info.parameter_count,
            .has_wildcard = info.has_wildcard,
        };
        return &self.pattern_routes[index];
    }

    fn find_pattern(self: *const Router, path: []const u8) ?u8 {
        var best: ?u8 = null;
        for (0..self.pattern_count) |index| {
            const route = self.pattern_routes[index];
            if (!pattern_matches(self.pattern_path(@intCast(index)), path)) continue;
            const current = best orelse {
                best = @intCast(index);
                continue;
            };
            const selected = self.pattern_routes[current];
            if (route.static_bytes > selected.static_bytes or
                (route.static_bytes == selected.static_bytes and
                    !route.has_wildcard and selected.has_wildcard) or
                (route.static_bytes == selected.static_bytes and
                    route.has_wildcard == selected.has_wildcard and
                    route.parameter_count < selected.parameter_count))
            {
                best = @intCast(index);
            }
        }
        return best;
    }

    fn allowed_method_mask(self: *const Router, node: u16) u16 {
        if (self.http_handlers[node][@intFromEnum(HttpMethod.any)] != null) {
            return all_method_mask;
        }

        var mask: u16 = 0;
        for (concrete_methods) |method| {
            if (self.http_handlers[node][@intFromEnum(method)] == null) continue;
            mask |= method_bit(method);
            if (method == .get) mask |= method_bit(.head);
        }
        if (self.ws_behaviors[node] != null) mask |= method_bit(.get);
        return mask;
    }
};

/// Formats a deterministic `Allow` field value into caller storage.
pub fn format_allowed_methods(mask: u16, buffer: []u8) ![]const u8 {
    var offset: usize = 0;

    for (concrete_methods) |method| {
        if (mask & method_bit(method) == 0) continue;

        const separator = if (offset == 0) "" else ", ";
        const method_name = method.name();
        if (separator.len + method_name.len > buffer.len - offset) return error.BufferTooSmall;

        @memcpy(buffer[offset .. offset + separator.len], separator);
        offset += separator.len;
        @memcpy(buffer[offset .. offset + method_name.len], method_name);
        offset += method_name.len;
    }
    return buffer[0..offset];
}

fn select_handler(
    handlers: *const [method_count]?RouteHandler,
    method: ?HttpMethod,
) ?RouteHandler {
    var handler: ?RouteHandler = null;
    if (method) |known_method| {
        handler = handlers[@intFromEnum(known_method)];
        if (handler == null and known_method == .head) {
            handler = handlers[@intFromEnum(HttpMethod.get)];
        }
    }
    if (handler == null) handler = handlers[@intFromEnum(HttpMethod.any)];
    return handler;
}

fn legacy_handler(handler: ?RouteHandler) ?Handler {
    const binding = handler orelse return null;
    return switch (binding) {
        .synchronous => |callback| callback,
        else => null,
    };
}

fn handlers_present(handlers: *const [method_count]?RouteHandler) bool {
    for (handlers) |handler| {
        if (handler != null) return true;
    }
    return false;
}

fn allowed_handler_mask(
    handlers: *const [method_count]?RouteHandler,
    has_websocket: bool,
) u16 {
    if (handlers[@intFromEnum(HttpMethod.any)] != null) return all_method_mask;

    var mask: u16 = 0;
    for (concrete_methods) |method| {
        if (handlers[@intFromEnum(method)] == null) continue;
        mask |= method_bit(method);
        if (method == .get) mask |= method_bit(.head);
    }
    if (has_websocket) mask |= method_bit(.get);
    return mask;
}

/// Segment shape used when comparing parameterized patterns.
const SegmentKind = enum {
    literal,
    capture,
    wildcard,
};

/// Classifies one validated pattern segment.
fn segment_kind(segment: []const u8) SegmentKind {
    if (segment.len == 0) return .literal;
    return switch (segment[0]) {
        ':' => .capture,
        '*' => .wildcard,
        else => .literal,
    };
}

/// Reports whether two parameterized patterns capture the same path shape:
/// equal segment counts, equal literal segments, and matching dynamic kinds.
///
/// Patterns that differ only in capture names would otherwise be silently
/// shadowed because one pattern is selected for every matching path.
fn same_pattern_skeleton(first: []const u8, second: []const u8) bool {
    var first_cursor: usize = 1;
    var second_cursor: usize = 1;

    while (true) {
        const first_end = std.mem.indexOfScalarPos(u8, first, first_cursor, '/') orelse first.len;
        const second_end = std.mem.indexOfScalarPos(u8, second, second_cursor, '/') orelse second.len;
        const first_segment = first[first_cursor..first_end];
        const second_segment = second[second_cursor..second_end];
        const first_kind = segment_kind(first_segment);
        const second_kind = segment_kind(second_segment);
        if (first_kind != second_kind) return false;
        if (first_kind == .literal and !std.mem.eql(u8, first_segment, second_segment)) {
            return false;
        }
        if (first_end == first.len or second_end == second.len) {
            return first_end == first.len and second_end == second.len;
        }
        first_cursor = first_end + 1;
        second_cursor = second_end + 1;
    }
}

fn pattern_matches(pattern: []const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var pattern_cursor: usize = 1;
    var path_cursor: usize = 1;

    while (pattern_cursor <= pattern.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_cursor, '/') orelse pattern.len;
        const segment = pattern[pattern_cursor..pattern_end];
        if (segment.len > 0 and segment[0] == '*') return true;

        const path_end = std.mem.indexOfScalarPos(u8, path, path_cursor, '/') orelse path.len;
        const value = path[path_cursor..path_end];
        if (segment.len > 0 and segment[0] == ':') {
            if (value.len == 0) return false;
        } else if (!std.mem.eql(u8, segment, value)) {
            return false;
        }

        if (pattern_end == pattern.len) return path_end == path.len;
        if (path_end == path.len) {
            pattern_cursor = pattern_end + 1;
            path_cursor = path.len;
            continue;
        }
        pattern_cursor = pattern_end + 1;
        path_cursor = path_end + 1;
    }
    return path_cursor == path.len;
}

fn capture_pattern(pattern: []const u8, path: []const u8, request: *Request) !void {
    var pattern_cursor: usize = 1;
    var path_cursor: usize = 1;

    while (pattern_cursor <= pattern.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_cursor, '/') orelse pattern.len;
        const segment = pattern[pattern_cursor..pattern_end];
        if (segment.len > 0 and segment[0] == '*') {
            try request.add_param(segment[1..], path[path_cursor..]);
            return;
        }

        const path_end = std.mem.indexOfScalarPos(u8, path, path_cursor, '/') orelse path.len;
        if (segment.len > 0 and segment[0] == ':') {
            try request.add_param(segment[1..], path[path_cursor..path_end]);
        }
        if (pattern_end == pattern.len) return;
        pattern_cursor = pattern_end + 1;
        path_cursor = if (path_end == path.len) path.len else path_end + 1;
    }
}

fn method_bit(method: HttpMethod) u16 {
    std.debug.assert(method != .any);
    return @as(u16, 1) << @as(u4, @intCast(@intFromEnum(method)));
}
