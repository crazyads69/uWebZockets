const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const radix = @import("../router/radix.zig");

pub const CorsOptions = struct {
    origins: []const []const u8,
    methods: []const radix.HttpMethod = &.{ .get, .head, .post },
    allow_headers: []const []const u8 = &.{},
    expose_headers: []const []const u8 = &.{},
    allow_credentials: bool = false,
    max_age: ?u32 = null,
};

pub const Cors = struct {
    options: CorsOptions,

    pub fn handler(context: *anyopaque, request: *Request, response: *Response) radix.MiddlewareResult {
        const self: *const Cors = @ptrCast(@alignCast(context));
        const origin = request.get_unique_header("origin") orelse return .continue_dispatch;
        if (!contains_exact(self.options.origins, origin)) return .continue_dispatch;

        response.append_header("Access-Control-Allow-Origin", origin) catch {
            fail_response(response);
            return .stop;
        };
        response.append_header("Vary", "Origin") catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.allow_credentials) {
            response.append_header("Access-Control-Allow-Credentials", "true") catch {
                fail_response(response);
                return .stop;
            };
        }
        append_list(response, "Access-Control-Expose-Headers", self.options.expose_headers) catch {
            fail_response(response);
            return .stop;
        };

        if (!std.mem.eql(u8, request.method, "OPTIONS")) return .continue_dispatch;
        const requested_method = request.get_unique_header("access-control-request-method") orelse {
            return .continue_dispatch;
        };
        const method = radix.HttpMethod.parse(requested_method) orelse {
            end_best_effort(response, "403 Forbidden");
            return .stop;
        };
        if (!contains_method(self.options.methods, method) or
            !requested_headers_allowed(request, self.options.allow_headers))
        {
            end_best_effort(response, "403 Forbidden");
            return .stop;
        }

        append_methods(response, self.options.methods) catch {
            fail_response(response);
            return .stop;
        };
        append_list(response, "Access-Control-Allow-Headers", self.options.allow_headers) catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.max_age) |max_age| {
            var value_buffer: [16]u8 = undefined;
            const value = std.fmt.bufPrint(&value_buffer, "{d}", .{max_age}) catch {
                fail_response(response);
                return .stop;
            };
            response.append_header("Access-Control-Max-Age", value) catch {
                fail_response(response);
                return .stop;
            };
        }
        end_best_effort(response, "204 No Content");
        return .stop;
    }
};

pub fn cors(options: CorsOptions) Cors {
    return .{ .options = options };
}

pub const SecurityHeadersOptions = struct {
    strict_transport_security: ?[]const u8 = "max-age=31536000; includeSubDomains",
    content_security_policy: ?[]const u8 = "default-src 'self'",
    x_content_type_options: bool = true,
    x_frame_options: ?[]const u8 = "DENY",
    referrer_policy: ?[]const u8 = "no-referrer",
};

pub const SecurityHeaders = struct {
    options: SecurityHeadersOptions,

    pub fn handler(context: *anyopaque, _: *Request, response: *Response) radix.MiddlewareResult {
        const self: *const SecurityHeaders = @ptrCast(@alignCast(context));
        append(response, "Strict-Transport-Security", self.options.strict_transport_security) catch {
            fail_response(response);
            return .stop;
        };
        append(response, "Content-Security-Policy", self.options.content_security_policy) catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.x_content_type_options) {
            response.append_header("X-Content-Type-Options", "nosniff") catch {
                fail_response(response);
                return .stop;
            };
        }
        append(response, "X-Frame-Options", self.options.x_frame_options) catch {
            fail_response(response);
            return .stop;
        };
        append(response, "Referrer-Policy", self.options.referrer_policy) catch {
            fail_response(response);
            return .stop;
        };
        return .continue_dispatch;
    }
};

pub fn security_headers(options: SecurityHeadersOptions) SecurityHeaders {
    return .{ .options = options };
}

/// One plaintext Basic credential accepted by `auth`.
pub const BasicCredential = struct {
    username: []const u8,
    password: []const u8,
};

/// One plaintext Bearer token accepted by `auth`.
pub const BearerToken = struct {
    token: []const u8,
};

/// Challenge realm and accepted credentials for `auth`.
pub const AuthOptions = struct {
    realm: []const u8 = "restricted",
    basic: []const BasicCredential = &.{},
    bearer: []const BearerToken = &.{},
};

/// Fixed-state Basic and Bearer authentication middleware.
///
/// Credentials are borrowed from the caller for the lifetime of the handler.
/// Each request decodes at most one 512-byte Basic payload on the stack and
/// compares credentials with a constant-time primitive. Missing, duplicate, or
/// invalid credentials receive `401 Unauthorized` with a challenge that lists
/// only the configured schemes.
pub const Auth = struct {
    options: AuthOptions,

    pub fn handler(context: *anyopaque, request: *Request, response: *Response) radix.MiddlewareResult {
        const self: *const Auth = @ptrCast(@alignCast(context));
        if (request.get_unique_header("authorization")) |value| {
            if (authorized(self.options, value)) return .continue_dispatch;
        }
        reject_auth(self.options, response);
        return .stop;
    }
};

/// Builds Basic and Bearer authentication over caller-owned credentials.
pub fn auth(options: AuthOptions) Auth {
    return .{ .options = options };
}

/// Maximum decoded credential bytes accepted from one Basic field.
const max_credential_bytes = 512;

/// Maximum formatted authentication challenge, including the realm.
const max_challenge_bytes = 1024;

/// Fixed block size used for constant-time credential comparison.
const comparison_block_bytes = 64;

fn authorized(options: AuthOptions, value: []const u8) bool {
    if (scheme_remainder(value, "Basic")) |encoded| return authorized_basic(options.basic, encoded);
    if (scheme_remainder(value, "Bearer")) |token| return authorized_bearer(options.bearer, token);
    return false;
}

/// Splits `value` after the case-insensitive `scheme` and its whitespace.
fn scheme_remainder(value: []const u8, scheme: []const u8) ?[]const u8 {
    if (value.len <= scheme.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..scheme.len], scheme)) return null;
    const separator = value[scheme.len];
    if (separator != ' ' and separator != '\t') return null;
    return std.mem.trimStart(u8, value[scheme.len..], " \t");
}

fn authorized_basic(credentials: []const BasicCredential, encoded: []const u8) bool {
    var decoded_buffer: [max_credential_bytes]u8 = undefined;
    const decoded = decode_basic(encoded, &decoded_buffer) orelse return false;
    const separator = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
    const username = decoded[0..separator];
    const password = decoded[separator + 1 ..];

    var matches: u1 = 0;
    for (credentials) |credential| {
        const username_equal: u1 = @intFromBool(constant_time_eql(username, credential.username));
        const password_equal: u1 = @intFromBool(constant_time_eql(password, credential.password));
        matches |= username_equal & password_equal;
    }
    return matches != 0;
}

fn authorized_bearer(tokens: []const BearerToken, token: []const u8) bool {
    if (token.len == 0) return false;
    var matches: u1 = 0;
    for (tokens) |candidate| {
        matches |= @intFromBool(constant_time_eql(token, candidate.token));
    }
    return matches != 0;
}

/// Decodes one RFC 4648 Basic payload into bounded caller storage.
fn decode_basic(encoded: []const u8, buffer: []u8) ?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return null;
    if (size > buffer.len) return null;
    decoder.decode(buffer[0..size], encoded) catch return null;
    return buffer[0..size];
}

/// Compares equal-length byte strings through a constant-time primitive.
///
/// Length is public metadata, so unequal lengths return false immediately.
/// Equal-length content is zero-padded into fixed blocks and compared with
/// `std.crypto.timing_safe.eql`, which never exits early.
fn constant_time_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    var index: usize = 0;
    while (index < a.len) : (index += comparison_block_bytes) {
        const count = @min(comparison_block_bytes, a.len - index);
        var left: [comparison_block_bytes]u8 = @splat(0);
        var right: [comparison_block_bytes]u8 = @splat(0);
        @memcpy(left[0..count], a[index..][0..count]);
        @memcpy(right[0..count], b[index..][0..count]);
        difference |= @intFromBool(!std.crypto.timing_safe.eql([comparison_block_bytes]u8, left, right));
    }
    return difference == 0;
}

fn reject_auth(options: AuthOptions, response: *Response) void {
    var buffer: [max_challenge_bytes]u8 = undefined;
    const challenge = format_challenge(&buffer, options) catch {
        fail_response(response);
        return;
    };
    if (challenge.len != 0) {
        response.append_header("WWW-Authenticate", challenge) catch {
            fail_response(response);
            return;
        };
    }
    end_best_effort(response, "401 Unauthorized");
}

/// Formats the challenge for the configured schemes without CR/LF or quotes
/// leaking out of the realm.
fn format_challenge(buffer: []u8, options: AuthOptions) ![]const u8 {
    const has_basic = options.basic.len != 0;
    const has_bearer = options.bearer.len != 0;
    if (has_basic and has_bearer) {
        try validate_realm(options.realm);
        return std.fmt.bufPrint(buffer, "Basic realm=\"{s}\", Bearer", .{options.realm});
    }
    if (has_basic) {
        try validate_realm(options.realm);
        return std.fmt.bufPrint(buffer, "Basic realm=\"{s}\"", .{options.realm});
    }
    if (has_bearer) return "Bearer";
    return "";
}

fn validate_realm(realm: []const u8) !void {
    if (std.mem.indexOfAny(u8, realm, "\"\r\n") != null) return error.InvalidRealm;
}

/// One caller-owned token bucket slot.
///
/// `last_refill_ns == 0` marks a free slot; the handler stores the monotonic
/// timestamp from `RateLimit.io` after every use.
pub const RateLimitBucket = struct {
    key: u64 = 0,
    tokens: u32 = 0,
    last_refill_ns: i128 = 0,
};

/// Derives the bucket key for one request.
pub const RateLimitKeyFn = *const fn (request: *const Request) u64;

/// Rate, burst, and key source for `rate_limit`.
pub const RateLimitOptions = struct {
    /// Tokens refilled per second; zero disables refill.
    rate_per_second: u32,
    /// Bucket capacity; zero uses `rate_per_second` with a minimum of one.
    burst: u32 = 0,
    /// Request header hashed with FNV-1a when present. Must be a
    /// server-derived value (for example `x-forwarded-for` behind a trusted
    /// proxy); an attacker-controlled header lets a client rotate keys.
    key_header: ?[]const u8 = null,
    /// Shared key used when no function or header value applies.
    key_constant: u64 = 0,
    /// Highest-precedence key source.
    key_fn: ?RateLimitKeyFn = null,
};

/// Outcome of one token-bucket step.
pub const RateLimitDecision = struct {
    allowed: bool,
    tokens: u32,
    last_refill_ns: i128,
    retry_after_seconds: u64,
};

/// Empty/open-addressing marker for an index entry.
const no_index = std.math.maxInt(u32);

/// One open-addressed key entry in a `RateLimitTable`.
pub const RateLimitIndexSlot = struct {
    key: u64 = 0,
    bucket: u32 = no_index,
    used: bool = false,
    tombstone: bool = false,
};

/// Per-bucket LRU link. `order` is a monotonic touch sequence; the head is
/// always the exact-oldest bucket.
pub const RateLimitLink = struct {
    next: u32 = no_index,
    prev: u32 = no_index,
    order: u64 = 0,
};

/// Caller-owned O(1) index and LRU over a fixed token-bucket table.
///
/// `slots.len` must be at least `2 * buckets.len`; `links.len` must equal
/// `buckets.len`. The table rebuilds its index at construction so a restored
/// or pre-seeded bucket array keeps the documented placement and eviction
/// order. Exactly one `RateLimit` owns a live table.
pub const RateLimitTable = struct {
    buckets: []RateLimitBucket,
    slots: []RateLimitIndexSlot,
    links: []RateLimitLink,
    head: u32 = no_index,
    tail: u32 = no_index,
    free_head: u32 = no_index,
    live: usize = 0,
    tombstones: usize = 0,
    /// Monotonic touch sequence used to order the LRU in O(1).
    sequence: u64 = 0,
    /// Test/diagnostic counter for probe work; never used for decisions.
    probe_count: usize = 0,

    pub const InitError = error{
        InvalidIndexCapacity,
        DuplicateRateLimitKey,
    };

    /// Builds the lookup index and LRU from the caller-owned buckets.
    pub fn init(
        buckets: []RateLimitBucket,
        slots: []RateLimitIndexSlot,
        links: []RateLimitLink,
    ) InitError!RateLimitTable {
        if (buckets.len != 0 and slots.len < buckets.len * 2) {
            return error.InvalidIndexCapacity;
        }
        if (links.len != buckets.len) return error.InvalidIndexCapacity;
        var table = RateLimitTable{
            .buckets = buckets,
            .slots = slots,
            .links = links,
        };
        try table.rebuild();
        return table;
    }

    /// Rebuilds the index and free list from the current bucket contents.
    pub fn rebuild(self: *RateLimitTable) InitError!void {
        @memset(self.slots, .{});
        self.head = no_index;
        self.tail = no_index;
        self.free_head = no_index;
        self.live = 0;
        self.tombstones = 0;
        self.sequence = 0;

        for (self.buckets, 0..) |bucket, index| {
            if (bucket.last_refill_ns == 0) {
                self.links[index] = .{ .next = self.free_head };
                self.free_head = @intCast(index);
                continue;
            }
            const slot = self.find_insert_slot(bucket.key) orelse
                return error.InvalidIndexCapacity;
            if (slot.duplicate) return error.DuplicateRateLimitKey;
            self.slots[slot.index] = .{
                .key = bucket.key,
                .bucket = @intCast(index),
                .used = true,
            };
            self.link_ordered(@intCast(index), bucket.last_refill_ns);
            self.live += 1;
        }
        self.assign_orders();
    }

    /// Inserts a bucket into the rebuilt LRU by (timestamp, index) order.
    ///
    /// Construction is the only O(n) path; live touches use `append_tail`.
    fn link_ordered(self: *RateLimitTable, bucket_index: u32, timestamp: i128) void {
        var position = self.tail;
        while (position != no_index) {
            const other = self.buckets[position];
            if (other.last_refill_ns < timestamp) break;
            if (other.last_refill_ns == timestamp and position < bucket_index) break;
            position = self.links[position].prev;
        }
        const link = &self.links[bucket_index];
        link.prev = position;
        link.next = if (position == no_index) self.head else self.links[position].next;
        if (link.next != no_index) {
            self.links[link.next].prev = bucket_index;
        } else {
            self.tail = bucket_index;
        }
        if (position == no_index) {
            self.head = bucket_index;
        } else {
            self.links[position].next = bucket_index;
        }
    }

    fn assign_orders(self: *RateLimitTable) void {
        var position = self.head;
        while (position != no_index) : (position = self.links[position].next) {
            self.sequence += 1;
            self.links[position].order = self.sequence;
        }
    }

    /// Returns the bucket index for `key`, inserting or evicting as needed.
    ///
    /// A hit refreshes the LRU position. A free-capacity insert is O(1)
    /// expected. A full-table miss evicts the exact oldest bucket; equal
    /// timestamps keep the lowest bucket index first.
    pub fn locate(self: *RateLimitTable, key: u64) ?BucketSlot {
        if (self.slots.len == 0) return null;
        // Bound probe cost after churn. Rebuilding before a mutation keeps
        // the bucket and index views consistent for the caller.
        if (self.tombstones > self.slots.len / 4) {
            self.reindex() catch return null;
        }
        var index = bucket_home(key, self.slots.len);
        var insert_at: ?usize = null;
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            self.probe_count += 1;
            const slot = self.slots[index];
            if (slot.used) {
                if (slot.key == key) {
                    self.touch(slot.bucket);
                    return .{ .index = slot.bucket, .matched = true, .evicted = false };
                }
            } else if (slot.tombstone) {
                if (insert_at == null) insert_at = index;
            } else {
                break;
            }
            index = if (index + 1 == self.slots.len) 0 else index + 1;
        }
        if (probes >= self.slots.len) {
            self.rebuild() catch return null;
            return self.locate(key);
        }

        const target = insert_at orelse index;
        var bucket_index: u32 = undefined;
        var evicted = false;
        if (self.free_head != no_index) {
            bucket_index = self.free_head;
            self.free_head = self.links[bucket_index].next;
            self.live += 1;
        } else if (self.live < self.buckets.len) {
            self.rebuild() catch return null;
            return self.locate(key);
        } else {
            bucket_index = self.head;
            if (bucket_index == no_index) return null;
            evicted = true;
            self.remove_index(self.buckets[bucket_index].key);
            self.unlink(bucket_index);
            self.live += 1;
        }

        self.slots[target] = .{
            .key = key,
            .bucket = bucket_index,
            .used = true,
        };
        self.append_tail(bucket_index);

        return .{ .index = bucket_index, .matched = false, .evicted = evicted };
    }

    /// Rebuilds only the lookup index, preserving live LRU order.
    fn reindex(self: *RateLimitTable) InitError!void {
        @memset(self.slots, .{});
        self.tombstones = 0;
        for (self.buckets, 0..) |bucket, index| {
            if (bucket.last_refill_ns == 0) continue;
            const slot = self.find_insert_slot(bucket.key) orelse
                return error.InvalidIndexCapacity;
            if (slot.duplicate) return error.DuplicateRateLimitKey;
            self.slots[slot.index] = .{
                .key = bucket.key,
                .bucket = @intCast(index),
                .used = true,
            };
        }
    }

    const InsertSlot = struct { index: usize, duplicate: bool };

    fn find_insert_slot(self: *RateLimitTable, key: u64) ?InsertSlot {
        if (self.slots.len == 0) return null;
        var index = bucket_home(key, self.slots.len);
        var insert_at: ?usize = null;
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            self.probe_count += 1;
            const slot = self.slots[index];
            if (slot.used) {
                if (slot.key == key) return .{ .index = index, .duplicate = true };
            } else if (slot.tombstone) {
                if (insert_at == null) insert_at = index;
            } else {
                return .{ .index = insert_at orelse index, .duplicate = false };
            }
            index = if (index + 1 == self.slots.len) 0 else index + 1;
        }
        return if (insert_at) |position| .{ .index = position, .duplicate = false } else null;
    }

    fn touch(self: *RateLimitTable, bucket_index: u32) void {
        self.unlink(bucket_index);
        self.append_tail(bucket_index);
    }

    fn append_tail(self: *RateLimitTable, bucket_index: u32) void {
        self.sequence +%= 1;
        if (self.sequence == 0) self.sequence = 1;
        self.links[bucket_index] = .{
            .next = no_index,
            .prev = self.tail,
            .order = self.sequence,
        };
        if (self.tail != no_index) {
            self.links[self.tail].next = bucket_index;
        } else {
            self.head = bucket_index;
        }
        self.tail = bucket_index;
    }

    fn unlink(self: *RateLimitTable, bucket_index: u32) void {
        const link = self.links[bucket_index];
        if (link.prev != no_index) {
            self.links[link.prev].next = link.next;
        } else {
            self.head = link.next;
        }
        if (link.next != no_index) {
            self.links[link.next].prev = link.prev;
        } else {
            self.tail = link.prev;
        }
        self.links[bucket_index] = .{};
    }

    fn remove_index(self: *RateLimitTable, key: u64) void {
        var index = bucket_home(key, self.slots.len);
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            const slot = &self.slots[index];
            if (!slot.used and !slot.tombstone) return;
            if (slot.used and slot.key == key) {
                slot.used = false;
                slot.tombstone = true;
                slot.bucket = no_index;
                self.tombstones += 1;
                if (self.live != 0) self.live -= 1;
                return;
            }
            index = if (index + 1 == self.slots.len) 0 else index + 1;
        }
    }
};

/// Fixed-state token-bucket rate-limit middleware.
///
/// The caller owns the bucket table and the `std.Io` used to read the
/// monotonic clock (`.awake`, which is `CLOCK_MONOTONIC` on Linux). Mutating
/// the caller-owned buckets and reading the clock is the documented purpose of
/// this boundary handler; it performs no allocation and takes no locks. A full
/// table evicts the bucket with the smallest `last_refill_ns` and starts the
/// evicted key empty, so rotating keys cannot reset a budget; an empty table
/// fails closed.
pub const RateLimit = struct {
    options: RateLimitOptions,
    buckets: []RateLimitBucket,
    io: std.Io,
    /// True when the table was empty at construction, so every occupied slot
    /// sits on its key's linear-probe path. Restored/pre-seeded tables keep
    /// the compatibility scan so their placement is never misread.
    probe_ready: bool = false,
    /// Optional O(1) index. Null keeps the documented linear compatibility
    /// path for callers that only pass buckets.
    table: ?RateLimitTable = null,

    pub fn handler(context: *anyopaque, request: *Request, response: *Response) radix.MiddlewareResult {
        const self: *RateLimit = @ptrCast(@alignCast(context));
        if (self.buckets.len == 0) {
            reject_limited(response, retry_after_seconds(self.options.rate_per_second));
            return .stop;
        }
        const now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
        const key = rate_limit_key(self.options, request);
        const slot = if (self.table) |*table|
            table.locate(key)
        else
            locate_bucket(self.buckets, key, self.probe_ready);
        const found = slot orelse {
            reject_limited(response, retry_after_seconds(self.options.rate_per_second));
            return .stop;
        };
        const bucket = &self.buckets[found.index];
        if (!found.matched) {
            // An evicted slot starts empty: a client that rotates an
            // attacker-controlled key must not reset its own budget. A free
            // slot starts full so a new peer is not punished for table churn.
            const seeded = if (found.evicted) 0 else effective_burst(self.options.rate_per_second, self.options.burst);
            bucket.* = .{
                .key = key,
                .tokens = @intCast(seeded),
                .last_refill_ns = now_ns,
            };
        }
        const decision = rate_limit_step(
            self.options.rate_per_second,
            self.options.burst,
            bucket.tokens,
            bucket.last_refill_ns,
            now_ns,
        );
        bucket.tokens = decision.tokens;
        bucket.last_refill_ns = decision.last_refill_ns;
        if (!decision.allowed) {
            reject_limited(response, decision.retry_after_seconds);
            return .stop;
        }
        return .continue_dispatch;
    }
};

/// Builds caller-owned token-bucket rate limiting over the supplied clock.
///
/// The bucket table is mutable limiter state and must be owned by exactly one
/// `RateLimit`. Sharing a live table between instances can mix the probe and
/// legacy placement modes.
pub fn rate_limit(io: std.Io, options: RateLimitOptions, buckets: []RateLimitBucket) RateLimit {
    var probe_ready = true;
    for (buckets) |bucket| {
        if (bucket.last_refill_ns != 0) {
            probe_ready = false;
            break;
        }
    }
    return .{
        .options = options,
        .buckets = buckets,
        .io = io,
        .probe_ready = probe_ready,
    };
}

/// Builds a rate limiter with caller-owned O(1) index and LRU storage.
///
/// `slots.len` must be at least twice `buckets.len` and `links.len` must equal
/// `buckets.len`. Construction rebuilds the index from the buckets, so a
/// restored table keeps its placement and exact-oldest tie break.
pub fn rate_limit_indexed(
    io: std.Io,
    options: RateLimitOptions,
    buckets: []RateLimitBucket,
    slots: []RateLimitIndexSlot,
    links: []RateLimitLink,
) RateLimitTable.InitError!RateLimit {
    const table = try RateLimitTable.init(buckets, slots, links);
    return .{
        .options = options,
        .buckets = buckets,
        .io = io,
        .probe_ready = false,
        .table = table,
    };
}

/// Refills one token bucket from monotonic time and charges one token.
///
/// Pure: the handler passes caller-owned bucket fields and the current
/// timestamp, so identical inputs produce identical decisions. `tokens` is
/// clamped to the effective burst and `last_refill_ns` keeps sub-token
/// remainder so refill stays continuous rather than windowed.
pub fn rate_limit_step(
    rate_per_second: u32,
    burst: u32,
    tokens: u32,
    last_refill_ns: i128,
    now_ns: i128,
) RateLimitDecision {
    const capacity = effective_burst(rate_per_second, burst);
    var available: u64 = @min(@as(u64, tokens), capacity);
    var baseline = last_refill_ns;

    if (now_ns <= baseline) {
        baseline = now_ns;
    } else if (available >= capacity) {
        // A full bucket does not bank idle time.
        baseline = now_ns;
    } else if (rate_per_second != 0) {
        // A baseline outside the i128 range refills completely.
        const elapsed = std.math.sub(i128, now_ns, baseline) catch std.math.maxInt(i128);
        const fill_ns: i128 = @as(i128, capacity) * std.time.ns_per_s;
        if (elapsed >= fill_ns) {
            available = capacity;
            baseline = now_ns;
        } else {
            // Clamp before scaling so the baseline advance cannot overflow and
            // a burst cannot over-refill past the missing tokens.
            const missing = capacity - available;
            const accrued_u128 = @min(
                @as(u128, missing),
                @as(u128, @intCast(elapsed)) * rate_per_second / std.time.ns_per_s,
            );
            const accrued: u64 = @intCast(accrued_u128);
            baseline += @intCast(accrued_u128 * std.time.ns_per_s / rate_per_second);
            available = @min(capacity, available + accrued);
        }
    }

    if (available == 0) {
        return .{
            .allowed = false,
            .tokens = 0,
            .last_refill_ns = baseline,
            .retry_after_seconds = retry_after_seconds(rate_per_second),
        };
    }
    return .{
        .allowed = true,
        .tokens = @intCast(available - 1),
        .last_refill_ns = baseline,
        .retry_after_seconds = 0,
    };
}

/// Returns the RFC 9110 Retry-After delay for an exhausted bucket.
///
/// An integer rate of at least one token per second reaches its next token
/// within one second, the header's resolution. A zero rate never refills, so
/// there is no meaningful retry delay and the caller omits the header.
fn retry_after_seconds(rate_per_second: u32) u64 {
    if (rate_per_second == 0) return 0;
    return 1;
}

/// Bucket capacity after the burst default and the one-token minimum.
fn effective_burst(rate_per_second: u32, burst: u32) u64 {
    const configured = if (burst == 0) rate_per_second else burst;
    return @max(1, @as(u64, configured));
}

/// Location of a request key inside the caller-owned bucket table.
const BucketSlot = struct {
    index: usize,
    matched: bool,
    /// True when the slot was occupied and evicted for this key.
    evicted: bool,
};

/// Finds `key`, else a free slot, else the oldest slot for eviction.
fn locate_bucket(buckets: []const RateLimitBucket, key: u64, probe_ready: bool) ?BucketSlot {
    if (buckets.len == 0) return null;
    if (!probe_ready) return locate_bucket_linear(buckets, key);

    var index = bucket_home(key, buckets.len);
    var oldest_index: usize = index;
    var oldest_ns: i128 = std.math.maxInt(i128);
    var visited: usize = 0;
    while (visited < buckets.len) : (visited += 1) {
        const bucket = buckets[index];
        if (bucket.last_refill_ns == 0) {
            return .{ .index = index, .matched = false, .evicted = false };
        }
        if (bucket.key == key) {
            return .{ .index = index, .matched = true, .evicted = false };
        }
        if (bucket.last_refill_ns < oldest_ns) {
            oldest_ns = bucket.last_refill_ns;
            oldest_index = index;
        }
        index = if (index + 1 == buckets.len) 0 else index + 1;
    }
    return .{ .index = oldest_index, .matched = false, .evicted = true };
}

/// Exact legacy scan for pre-populated tables.
fn locate_bucket_linear(buckets: []const RateLimitBucket, key: u64) ?BucketSlot {
    var free: ?usize = null;
    var oldest_index: usize = 0;
    var oldest_ns: i128 = std.math.maxInt(i128);
    for (buckets, 0..) |bucket, index| {
        if (bucket.last_refill_ns == 0) {
            if (free == null) free = index;
            continue;
        }
        if (bucket.key == key) return .{ .index = index, .matched = true, .evicted = false };
        if (bucket.last_refill_ns < oldest_ns) {
            oldest_ns = bucket.last_refill_ns;
            oldest_index = index;
        }
    }
    if (free) |index| return .{ .index = index, .matched = false, .evicted = false };
    return .{ .index = oldest_index, .matched = false, .evicted = true };
}

/// Maps a key to its first probe slot with a splitmix64 finalizer.
fn bucket_home(key: u64, len: usize) usize {
    var value = key;
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    value *%= 0x94d049bb133111eb;
    value ^= value >> 31;
    return @intCast(value % len);
}

/// Resolves the bucket key: custom function, hashed header, or constant.
fn rate_limit_key(options: RateLimitOptions, request: *const Request) u64 {
    if (options.key_fn) |key_fn| return key_fn(request);
    const header_name = options.key_header orelse return options.key_constant;
    const value = request.get_header(header_name) orelse return options.key_constant;
    return fnv1a_64(value);
}

/// Hashes bytes with 64-bit FNV-1a, the stable derivation for header keys.
pub fn fnv1a_64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn reject_limited(response: *Response, retry_after: u64) void {
    if (retry_after != 0) {
        var buffer: [20]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{d}", .{retry_after}) catch {
            fail_response(response);
            return;
        };
        response.append_header("Retry-After", value) catch {
            fail_response(response);
            return;
        };
    }
    end_best_effort(response, "429 Too Many Requests");
}

fn requested_headers_allowed(request: *const Request, allowed: []const []const u8) bool {
    const value = request.get_unique_header("access-control-request-headers") orelse return true;
    var headers = std.mem.splitScalar(u8, value, ',');
    while (headers.next()) |raw_header| {
        const header = std.mem.trim(u8, raw_header, " \t");
        var found = false;
        for (allowed) |candidate| {
            if (!std.ascii.eqlIgnoreCase(candidate, header)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn contains_exact(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn contains_method(methods: []const radix.HttpMethod, expected: radix.HttpMethod) bool {
    for (methods) |method| {
        if (method == expected or method == .any) return true;
    }
    return false;
}

fn append(response: *Response, name: []const u8, value: ?[]const u8) !void {
    if (value) |present| try response.append_header(name, present);
}

fn append_list(response: *Response, name: []const u8, values: []const []const u8) !void {
    if (values.len == 0) return;
    var buffer: [1024]u8 = undefined;
    const value = try format_list(&buffer, values);
    try response.append_header(name, value);
}

fn append_methods(response: *Response, methods: []const radix.HttpMethod) !void {
    var names: [10][]const u8 = undefined;
    if (methods.len > names.len) return error.TooManyCorsMethods;
    for (methods, 0..) |method, index| names[index] = method.name();
    try append_list(response, "Access-Control-Allow-Methods", names[0..methods.len]);
}

fn format_list(buffer: []u8, values: []const []const u8) ![]const u8 {
    var offset: usize = 0;
    for (values, 0..) |value, index| {
        if (std.mem.indexOfAny(u8, value, "\r\n,") != null) return error.InvalidHeaderValue;
        const separator = if (index == 0) "" else ", ";
        if (separator.len + value.len > buffer.len - offset) return error.BufferTooSmall;
        @memcpy(buffer[offset..][0..separator.len], separator);
        offset += separator.len;
        @memcpy(buffer[offset..][0..value.len], value);
        offset += value.len;
    }
    return buffer[0..offset];
}

fn fail_response(response: *Response) void {
    end_best_effort(response, "500 Internal Server Error");
}

fn end_best_effort(response: *Response, status: []const u8) void {
    // The middleware ABI cannot report a response failure after dispatch stops.
    response.end(status, "") catch {};
}
