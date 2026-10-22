const std = @import("std");

/// RFC 9220/RFC 8441 setting that permits extended CONNECT requests.
pub const settings_enable_connect_protocol: u64 = 0x08;
/// HTTP/3 unidirectional stream type carrying a promised response.
pub const push_stream_type: u64 = 0x01;
/// HTTP/3 frame type used by a client to cancel a promised response.
pub const cancel_push_frame_type: u64 = 0x03;
/// HTTP/3 frame type associating request fields with a push identifier.
pub const push_promise_frame_type: u64 = 0x05;
/// HTTP/3 frame type that raises the peer's permitted push identifier.
pub const max_push_id_frame_type: u64 = 0x0d;
/// HTTP/3 application error indicating cancellation of a request or push.
pub const h3_request_cancelled: u64 = 0x10c;
/// HTTP/3 application error indicating an invalid push identifier.
pub const h3_id_error: u64 = 0x108;

/// Backend primitives available to higher-level HTTP/3 extensions.
///
/// Capability records are declarative; setting a bit does not configure the
/// backend. Callers must advertise protocol settings only after the matching
/// primitives have been enabled successfully.
pub const BackendCapabilities = struct {
    /// The backend can advertise and process SETTINGS_ENABLE_CONNECT_PROTOCOL.
    extended_connect_setting: bool = false,
    /// The backend can emit PUSH_PROMISE and server push streams.
    server_push: bool = false,
    /// The backend can send and receive QUIC DATAGRAM frames.
    quic_datagrams: bool = false,
    /// The backend can open application-controlled unidirectional streams.
    outgoing_unidirectional_streams: bool = false,
    /// The backend implements RESET_STREAM_AT transport semantics.
    reset_stream_at: bool = false,
    /// The backend wire behavior matches WebTransport-over-HTTP/3 draft 16.
    webtransport_draft_16: bool = false,
};

/// Capabilities actually exposed by the pinned lsquic 4.10.2 integration.
///
/// Raw datagram callbacks are available; server push and the primitives
/// required by WebTransport draft 16 remain explicitly unsupported.
pub const lsquic_4_10_0_capabilities: BackendCapabilities = .{
    .quic_datagrams = true,
};

/// Borrowed fields consumed by the current HTTP/3 WebSocket CONNECT validator.
///
/// All slices must remain valid only for the duration of validation. Counts
/// are supplied separately so duplicate fields can be rejected without
/// allocating or retaining a header list.
pub const WebSocketConnect = struct {
    /// `:method` value; validation requires `CONNECT`.
    method: []const u8,
    /// `:protocol` value; validation requires `websocket`.
    protocol: ?[]const u8,
    /// `:scheme` value; validation accepts `http` and `https`.
    scheme: ?[]const u8,
    /// Non-empty `:authority` value.
    authority: ?[]const u8,
    /// Absolute-path `:path` value.
    path: ?[]const u8,
    /// Borrowed `sec-websocket-version` value, if present.
    websocket_version: ?[]const u8,
    /// Number of decoded `sec-websocket-version` fields.
    websocket_version_count: usize,
    /// Whether a forbidden HTTP/1.1 `connection` field was present.
    has_connection_header: bool,
    /// Whether a forbidden HTTP/1.1 `upgrade` field was present.
    has_upgrade_header: bool,
};

/// Validation failures for an HTTP/3 WebSocket extended CONNECT request.
pub const WebSocketConnectError = error{
    /// `:method` was not `CONNECT`.
    InvalidMethod,
    /// `:protocol` was absent.
    MissingProtocol,
    /// `:protocol` named an unsupported protocol.
    UnsupportedProtocol,
    /// `:scheme` was absent or was neither `http` nor `https`.
    InvalidScheme,
    /// `:authority` was absent or empty.
    MissingAuthority,
    /// `:path` was absent, empty, or not absolute.
    InvalidPath,
    /// A connection-specific HTTP/1.1 field was present.
    ConnectionSpecificHeader,
    /// No WebSocket version field was present.
    MissingVersion,
    /// More than one WebSocket version field was present.
    DuplicateVersion,
    /// The WebSocket version was not 13.
    UnsupportedVersion,
};

/// Validates a borrowed extended CONNECT request without allocating.
///
/// The function validates pseudo-fields, duplicate counts, forbidden
/// connection fields, and WebSocket version 13. RFC 8441 key/accept processing
/// is intentionally absent. The function retains no slice from `connect`.
pub fn validate_websocket_connect(connect: WebSocketConnect) WebSocketConnectError!void {
    if (!std.mem.eql(u8, connect.method, "CONNECT")) return error.InvalidMethod;

    const protocol = connect.protocol orelse return error.MissingProtocol;
    if (!std.mem.eql(u8, protocol, "websocket")) return error.UnsupportedProtocol;

    const scheme = connect.scheme orelse return error.InvalidScheme;
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) {
        return error.InvalidScheme;
    }
    if (connect.authority == null or connect.authority.?.len == 0) {
        return error.MissingAuthority;
    }
    if (connect.path == null or connect.path.?.len == 0 or connect.path.?[0] != '/') {
        return error.InvalidPath;
    }
    if (connect.has_connection_header or connect.has_upgrade_header) {
        return error.ConnectionSpecificHeader;
    }

    if (connect.websocket_version_count == 0) return error.MissingVersion;
    if (connect.websocket_version_count != 1) return error.DuplicateVersion;
    const version = connect.websocket_version orelse return error.MissingVersion;
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t"), "13")) {
        return error.UnsupportedVersion;
    }
}

/// Maps validation failures to the HTTP status used before tunnel creation.
pub fn websocket_error_status(connect_error: WebSocketConnectError) u16 {
    return switch (connect_error) {
        error.UnsupportedProtocol => 501,
        error.UnsupportedVersion => 426,
        else => 400,
    };
}

/// Application policy for requests that arrive before handshake confirmation.
pub const EarlyDataPolicy = enum(u8) {
    /// Reject every request identified as early data.
    reject,
    /// Queue early requests until the TLS handshake is confirmed.
    defer_until_confirmed,
    /// Process only requests the application marked replay-safe.
    allow_replay_safe,
};

/// TLS handshake state relevant to application request dispatch.
pub const HandshakeState = enum(u8) {
    /// Authentication and confirmation are still pending.
    in_progress,
    /// The handshake is confirmed and normal dispatch is permitted.
    confirmed,
    /// The handshake failed and the connection must close.
    failed,
};

/// Facts used to make a zero-allocation early-data dispatch decision.
pub const EarlyDataContext = struct {
    /// Current handshake state.
    handshake: HandshakeState,
    /// Whether the request bytes arrived before confirmation.
    arrived_before_confirmation: bool,
    /// Whether a trusted upstream marked the request as forwarded early data.
    forwarded_early_data: bool,
    /// Whether the application has classified the operation as replay-safe.
    replay_safe: bool,
};

/// Action selected for a request under the configured early-data policy.
pub const EarlyDataDecision = enum(u8) {
    /// Dispatch the request now.
    process,
    /// Retain the request in bounded caller-owned storage until confirmation.
    deferred,
    /// Reject the request, normally with HTTP status 425.
    reject_too_early,
    /// Close because the TLS handshake failed.
    close_connection,
};

/// Applies application early-data policy without allocating or retaining state.
pub fn decide_early_data(policy: EarlyDataPolicy, context: EarlyDataContext) EarlyDataDecision {
    if (context.handshake == .failed) return .close_connection;
    if (context.forwarded_early_data and !context.replay_safe) return .reject_too_early;
    if (!context.arrived_before_confirmation) return .process;

    return switch (policy) {
        .reject => .reject_too_early,
        .defer_until_confirmed => if (context.handshake == .confirmed) .process else .deferred,
        .allow_replay_safe => if (context.replay_safe) .process else .reject_too_early,
    };
}

/// Reports whether an uppercase method has safe semantics for replay policy.
///
/// The default set includes RFC 10008 `QUERY`. This classification does not
/// prove application-level idempotence or authorize 0-RTT by itself.
pub fn method_is_replay_safe(method: []const u8) bool {
    return std.mem.eql(u8, method, "GET") or
        std.mem.eql(u8, method, "HEAD") or
        std.mem.eql(u8, method, "OPTIONS") or
        std.mem.eql(u8, method, "QUERY") or
        std.mem.eql(u8, method, "TRACE");
}

/// Lifecycle of a locally allocated HTTP/3 push identifier.
pub const PushState = enum(u8) {
    /// An identifier is allocated but no PUSH_PROMISE was emitted.
    reserved,
    /// A PUSH_PROMISE was emitted for the identifier.
    promised,
    /// The corresponding push stream has begun.
    streaming,
};

/// Failures from bounded HTTP/3 push bookkeeping.
pub const PushError = error{
    /// The selected transport backend cannot emit server push.
    BackendUnsupported,
    /// The peer has not supplied MAX_PUSH_ID.
    PushNotEnabled,
    /// A later MAX_PUSH_ID attempted to lower the permitted identifier.
    PushIdReduced,
    /// No identifier remains within the peer's advertised range.
    PushIdExhausted,
    /// Every compile-time bookkeeping slot is active.
    CapacityExceeded,
    /// The identifier is not active in this table.
    UnknownPush,
    /// The requested lifecycle transition is out of order.
    InvalidTransition,
};

/// Returns fixed-capacity, allocation-free server-push bookkeeping.
///
/// `capacity` bounds simultaneous active pushes at compile time. Storage is
/// embedded in the returned value; the value must not be copied after use
/// begins because copies would diverge. Push identifiers are monotonic and are
/// never reused even after their slots are released.
pub fn push_bookkeeping(comptime capacity: usize) type {
    if (capacity == 0) @compileError("push capacity must be greater than zero");

    return struct {
        const Self = @This();

        /// Push IDs indexed by slot; callers must not mutate this storage.
        push_ids: [capacity]u64 = .{0} ** capacity,
        /// Lifecycle states parallel to `push_ids`; callers must not mutate them.
        states: [capacity]PushState = .{.reserved} ** capacity,
        /// Embedded free-slot stack initialized by `init`.
        free_indices: [capacity]usize = undefined,
        /// Slots currently assigned to active push IDs.
        active: std.StaticBitSet(capacity) = .empty,
        /// Largest push ID permitted by the peer, or `null` before MAX_PUSH_ID.
        maximum_push_id: ?u64 = null,
        /// Next monotonically allocated push ID.
        next_push_id: u64 = 0,
        /// Number of entries remaining on the free-slot stack.
        free_count: usize = capacity,
        /// Whether the full QUIC-varint ID space has been consumed.
        ids_exhausted: bool = false,

        /// Initializes the embedded free-slot stack without allocating.
        pub fn init() Self {
            var self = Self{};
            for (&self.free_indices, 0..) |*slot, index| slot.* = index;
            return self;
        }

        /// Applies a monotonic peer MAX_PUSH_ID value.
        ///
        /// Repeating the current value is idempotent; decreasing it or passing
        /// a value outside the QUIC varint range fails without changing it.
        pub fn apply_max_push_id(self: *Self, push_id: u64) PushError!void {
            if (push_id > max_quic_varint) return error.PushIdExhausted;
            if (self.maximum_push_id) |current| {
                if (push_id < current) return error.PushIdReduced;
                if (push_id == current) return;
            }
            self.maximum_push_id = push_id;
        }

        /// Reserves the next permitted identifier and one embedded slot.
        ///
        /// No state changes on failure. The caller must subsequently call
        /// `mark_promised`, `mark_streaming`, and eventually `release`.
        pub fn reserve(self: *Self, capabilities: BackendCapabilities) PushError!u64 {
            if (!capabilities.server_push) return error.BackendUnsupported;
            const maximum = self.maximum_push_id orelse return error.PushNotEnabled;
            if (self.ids_exhausted or self.next_push_id > maximum) return error.PushIdExhausted;
            if (self.free_count == 0) return error.CapacityExceeded;

            self.free_count -= 1;
            const slot = self.free_indices[self.free_count];
            const push_id = self.next_push_id;
            self.push_ids[slot] = push_id;
            self.states[slot] = .reserved;
            self.active.set(slot);

            if (push_id == max_quic_varint) {
                self.ids_exhausted = true;
            } else {
                self.next_push_id += 1;
            }
            return push_id;
        }

        /// Advances a reserved identifier after PUSH_PROMISE is emitted.
        pub fn mark_promised(self: *Self, push_id: u64) PushError!void {
            const slot = self.find(push_id) orelse return error.UnknownPush;
            if (self.states[slot] != .reserved) return error.InvalidTransition;
            self.states[slot] = .promised;
        }

        /// Advances a promised identifier after its push stream begins.
        pub fn mark_streaming(self: *Self, push_id: u64) PushError!void {
            const slot = self.find(push_id) orelse return error.UnknownPush;
            if (self.states[slot] != .promised) return error.InvalidTransition;
            self.states[slot] = .streaming;
        }

        /// Releases an active identifier's slot without making the ID reusable.
        pub fn release(self: *Self, push_id: u64) PushError!void {
            const slot = self.find(push_id) orelse return error.UnknownPush;
            self.active.unset(slot);
            self.free_indices[self.free_count] = slot;
            self.free_count += 1;
        }

        /// Returns the lifecycle state of an active identifier, or `null`.
        pub fn state(self: *const Self, push_id: u64) ?PushState {
            const slot = self.find(push_id) orelse return null;
            return self.states[slot];
        }

        /// Returns the number of currently active push slots.
        pub fn count(self: *const Self) usize {
            return capacity - self.free_count;
        }

        fn find(self: *const Self, push_id: u64) ?usize {
            var iterator = self.active.iterator(.{});
            while (iterator.next()) |slot| {
                if (self.push_ids[slot] == push_id) return slot;
            }
            return null;
        }
    };
}

const max_quic_varint: u64 = (1 << 62) - 1;
