//! Middleware suite for authentication and rate limiting.
const std = @import("std");
const support = @import("test_support");

const Request = support.http_request.Request;
const Response = support.http_response.Response;
const middleware = support.middleware;

/// Minimal HTTP/3 target that records one response for assertions.
const ResponseCapture = struct {
    status: [64]u8 = undefined,
    status_len: usize = 0,
    headers: [1024]u8 = undefined,
    headers_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,
    finished: bool = false,

    fn target(self: *ResponseCapture) support.http_response.Http3Target {
        return .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        };
    }

    fn end(context: *anyopaque, response_status: []const u8, headers: []const u8, body: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (response_status.len > self.status.len or headers.len > self.headers.len or body.len > self.body.len) {
            return error.BufferOverflow;
        }
        @memcpy(self.status[0..response_status.len], response_status);
        self.status_len = response_status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        @memcpy(self.body[0..body.len], body);
        self.body_len = body.len;
        self.finished = true;
    }

    fn begin(context: *anyopaque, response_status: []const u8, headers: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (response_status.len > self.status.len or headers.len > self.headers.len) return error.BufferOverflow;
        @memcpy(self.status[0..response_status.len], response_status);
        self.status_len = response_status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
    }

    fn write(context: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (chunk.len > self.body.len - self.body_len) return error.BufferOverflow;
        @memcpy(self.body[self.body_len..][0..chunk.len], chunk);
        self.body_len += chunk.len;
    }

    fn finish(context: *anyopaque) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        self.finished = true;
    }

    fn status_line(self: *const ResponseCapture) []const u8 {
        return self.status[0..self.status_len];
    }

    fn header_bytes(self: *const ResponseCapture) []const u8 {
        return self.headers[0..self.headers_len];
    }
};

/// Fills `request` with exactly one header entry.
fn header_request(name: []const u8, value: []const u8) Request {
    var request = Request{};
    request.header_names[0] = name;
    request.header_values[0] = value;
    request.header_count = 1;
    return request;
}

fn run_auth(handler: *middleware.Auth, request: *Request, capture: *ResponseCapture) !support.radix.MiddlewareResult {
    var response = Response{ .target = .{ .http3 = capture.target() } };
    return middleware.Auth.handler(handler, request, &response);
}

fn run_rate_limit(
    handler: *middleware.RateLimit,
    request: *Request,
    capture: *ResponseCapture,
) !support.radix.MiddlewareResult {
    var response = Response{ .target = .{ .http3 = capture.target() } };
    return middleware.RateLimit.handler(handler, request, &response);
}

const alice = middleware.BasicCredential{ .username = "alice", .password = "secret" };

test "auth: accepts a valid Basic credential" {
    var handler = middleware.auth(.{ .basic = &.{alice} });
    // base64("alice:secret") is YWxpY2U6c2VjcmV0.
    var request = header_request("Authorization", "Basic YWxpY2U6c2VjcmV0");
    var capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.continue_dispatch,
        try run_auth(&handler, &request, &capture),
    );
    try std.testing.expect(!capture.finished);
}

test "auth: accepts a valid Bearer token with a case-insensitive scheme" {
    var handler = middleware.auth(.{ .bearer = &.{.{ .token = "token-123" }} });
    var request = header_request("authorization", "bearer token-123");
    var capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.continue_dispatch,
        try run_auth(&handler, &request, &capture),
    );
    try std.testing.expect(!capture.finished);
}

test "auth: rejects a missing credential with both configured challenges" {
    var handler = middleware.auth(.{ .basic = &.{alice}, .bearer = &.{.{ .token = "token-123" }} });
    var request = Request{};
    var capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &request, &capture),
    );
    try std.testing.expectEqualStrings("401 Unauthorized", capture.status_line());
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.header_bytes(),
        "WWW-Authenticate: Basic realm=\"restricted\", Bearer\r\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), capture.body_len);
    try std.testing.expect(capture.finished);
}

test "auth: rejects malformed and duplicate Authorization fields" {
    var handler = middleware.auth(.{ .basic = &.{alice} });
    const malformed = [_][]const u8{
        "Basic",
        "Basic ",
        "Basic !!!!",
        "Basic YWxpY2U=",
        "Bearer",
        "Bearer ",
        "Digest abc",
    };
    for (malformed) |value| {
        var request = header_request("Authorization", value);
        var capture = ResponseCapture{};
        try std.testing.expectEqual(
            support.radix.MiddlewareResult.stop,
            try run_auth(&handler, &request, &capture),
        );
        try std.testing.expectEqualStrings("401 Unauthorized", capture.status_line());
    }

    var duplicate = Request{};
    duplicate.header_names[0] = "Authorization";
    duplicate.header_values[0] = "Basic YWxpY2U6c2VjcmV0";
    duplicate.header_names[1] = "authorization";
    duplicate.header_values[1] = "Basic YWxpY2U6c2VjcmV0";
    duplicate.header_count = 2;
    var duplicate_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &duplicate, &duplicate_capture),
    );
    try std.testing.expectEqualStrings("401 Unauthorized", duplicate_capture.status_line());
}

test "auth: rejects wrong, oversized, and wrong-scheme credentials" {
    var handler = middleware.auth(.{
        .basic = &.{alice},
        .bearer = &.{.{ .token = "token-123" }},
    });
    // base64("alice:wrong") is YWxpY2U6d3Jvbmc=.
    var wrong_basic = header_request("Authorization", "Basic YWxpY2U6d3Jvbmc=");
    var wrong_basic_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &wrong_basic, &wrong_basic_capture),
    );

    var wrong_bearer = header_request("Authorization", "Bearer token-999");
    var wrong_bearer_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &wrong_bearer, &wrong_bearer_capture),
    );

    var oversized = header_request("Authorization", "Basic " ++ ([_]u8{'A'} ** 700));
    var oversized_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &oversized, &oversized_capture),
    );
    try std.testing.expectEqualStrings("401 Unauthorized", oversized_capture.status_line());
}

test "auth: challenges list only the configured schemes" {
    var basic_only = middleware.auth(.{ .realm = "ops", .basic = &.{alice} });
    var basic_request = Request{};
    var basic_capture = ResponseCapture{};
    _ = try run_auth(&basic_only, &basic_request, &basic_capture);
    try std.testing.expect(std.mem.indexOf(
        u8,
        basic_capture.header_bytes(),
        "WWW-Authenticate: Basic realm=\"ops\"\r\n",
    ) != null);

    var bearer_only = middleware.auth(.{ .bearer = &.{.{ .token = "token-123" }} });
    var bearer_request = Request{};
    var bearer_capture = ResponseCapture{};
    _ = try run_auth(&bearer_only, &bearer_request, &bearer_capture);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bearer_capture.header_bytes(),
        "WWW-Authenticate: Bearer\r\n",
    ) != null);

    var unconfigured = middleware.auth(.{});
    var unconfigured_request = Request{};
    var unconfigured_capture = ResponseCapture{};
    _ = try run_auth(&unconfigured, &unconfigured_request, &unconfigured_capture);
    try std.testing.expectEqualStrings("401 Unauthorized", unconfigured_capture.status_line());
    try std.testing.expect(std.mem.indexOf(u8, unconfigured_capture.header_bytes(), "WWW-Authenticate") == null);
}

test "auth: an unformattable realm falls back to the failure response" {
    var handler = middleware.auth(.{ .realm = "bad\"realm", .basic = &.{alice} });
    var request = Request{};
    var capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_auth(&handler, &request, &capture),
    );
    try std.testing.expectEqualStrings("500 Internal Server Error", capture.status_line());
    try std.testing.expect(std.mem.indexOf(u8, capture.header_bytes(), "WWW-Authenticate") == null);
}

test "rate limit: token math refills continuously and charges one token" {
    const first = middleware.rate_limit_step(2, 2, 2, 1_000_000_000, 1_000_000_000);
    try std.testing.expect(first.allowed);
    try std.testing.expectEqual(@as(u32, 1), first.tokens);
    try std.testing.expectEqual(@as(u64, 0), first.retry_after_seconds);

    const second = middleware.rate_limit_step(2, 2, first.tokens, first.last_refill_ns, 1_000_000_000);
    try std.testing.expect(second.allowed);
    try std.testing.expectEqual(@as(u32, 0), second.tokens);

    const third = middleware.rate_limit_step(2, 2, second.tokens, second.last_refill_ns, 1_000_000_000);
    try std.testing.expect(!third.allowed);
    try std.testing.expectEqual(@as(u32, 0), third.tokens);
    try std.testing.expectEqual(@as(u64, 1), third.retry_after_seconds);

    // Half a refill window at two tokens per second restores exactly one token.
    const fourth = middleware.rate_limit_step(2, 2, third.tokens, third.last_refill_ns, 1_500_000_000);
    try std.testing.expect(fourth.allowed);
    try std.testing.expectEqual(@as(u32, 0), fourth.tokens);

    const fifth = middleware.rate_limit_step(2, 2, fourth.tokens, fourth.last_refill_ns, 2_000_000_000);
    try std.testing.expect(fifth.allowed);
    try std.testing.expectEqual(@as(u32, 0), fifth.tokens);
}

test "rate limit: burst defaults to the rate, saturates, and zero rate never refills" {
    var state = middleware.rate_limit_step(3, 0, 3, 1_000_000_000, 1_000_000_000);
    try std.testing.expect(state.allowed);
    try std.testing.expectEqual(@as(u32, 2), state.tokens);

    // Long idle time refills only to the burst and still charges one token.
    state = middleware.rate_limit_step(3, 0, 0, state.last_refill_ns, 100_000_000_000);
    try std.testing.expect(state.allowed);
    try std.testing.expectEqual(@as(u32, 2), state.tokens);

    const zero_rate = middleware.rate_limit_step(0, 2, 2, 1_000_000_000, 1_000_000_000);
    try std.testing.expect(zero_rate.allowed);
    const zero_rate_second = middleware.rate_limit_step(
        0,
        2,
        zero_rate.tokens,
        zero_rate.last_refill_ns,
        1_000_000_000,
    );
    try std.testing.expect(zero_rate_second.allowed);
    const zero_rate_denied = middleware.rate_limit_step(
        0,
        2,
        zero_rate_second.tokens,
        zero_rate_second.last_refill_ns,
        5_000_000_000,
    );
    try std.testing.expect(!zero_rate_denied.allowed);
}

test "rate limit: extreme rates and idle gaps cannot overflow the refill math" {
    // Regression: elapsed * rate and the baseline advance must not wrap u64.
    const refilled = middleware.rate_limit_step(
        4_000_000_000,
        0,
        0,
        1_000_000_000,
        6_000_000_000,
    );
    try std.testing.expect(refilled.allowed);
    try std.testing.expectEqual(@as(u32, 3_999_999_999), refilled.tokens);

    const clamped = middleware.rate_limit_step(
        1_000_000,
        4,
        0,
        0,
        5_000_000_000,
    );
    try std.testing.expect(clamped.allowed);
    try std.testing.expectEqual(@as(u32, 3), clamped.tokens);
}

test "rate limit: a zero rate omits Retry-After because no retry arrives" {
    var buckets = [_]middleware.RateLimitBucket{.{}};
    var limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 0,
        .burst = 1,
        .key_constant = 3,
    }, &buckets);

    var request = Request{};
    var allowed_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.continue_dispatch,
        try run_rate_limit(&limiter, &request, &allowed_capture),
    );

    var rejected_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_rate_limit(&limiter, &request, &rejected_capture),
    );
    try std.testing.expectEqualStrings("429 Too Many Requests", rejected_capture.status_line());
    try std.testing.expect(std.mem.indexOf(u8, rejected_capture.header_bytes(), "Retry-After") == null);
}

test "rate limit: handler allows the burst then rejects with Retry-After" {
    var buckets = [_]middleware.RateLimitBucket{.{}};
    var limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 1,
        .burst = 2,
        .key_constant = 7,
    }, &buckets);

    var request = Request{};
    inline for (0..2) |_| {
        var capture = ResponseCapture{};
        try std.testing.expectEqual(
            support.radix.MiddlewareResult.continue_dispatch,
            try run_rate_limit(&limiter, &request, &capture),
        );
    }

    var rejected_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_rate_limit(&limiter, &request, &rejected_capture),
    );
    try std.testing.expectEqualStrings("429 Too Many Requests", rejected_capture.status_line());
    try std.testing.expect(std.mem.indexOf(u8, rejected_capture.header_bytes(), "Retry-After: 1\r\n") != null);
    try std.testing.expectEqual(@as(usize, 0), rejected_capture.body_len);
    try std.testing.expectEqual(@as(u64, 7), buckets[0].key);
}

test "rate limit: keys follow function, header hash, then constant precedence" {
    const constant_key = struct {
        fn call(_: *const Request) u64 {
            return 99;
        }
    }.call;

    var function_buckets = [_]middleware.RateLimitBucket{.{}};
    var function_limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 5,
        .key_header = "x-tenant",
        .key_constant = 4,
        .key_fn = constant_key,
    }, &function_buckets);
    var function_request = header_request("x-tenant", "tenant-a");
    var function_capture = ResponseCapture{};
    _ = try run_rate_limit(&function_limiter, &function_request, &function_capture);
    try std.testing.expectEqual(@as(u64, 99), function_buckets[0].key);

    var header_buckets = [_]middleware.RateLimitBucket{.{}};
    var header_limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 5,
        .key_header = "x-tenant",
        .key_constant = 4,
    }, &header_buckets);
    var header_value_request = header_request("X-Tenant", "tenant-a");
    var header_capture = ResponseCapture{};
    _ = try run_rate_limit(&header_limiter, &header_value_request, &header_capture);
    try std.testing.expectEqual(middleware.fnv1a_64("tenant-a"), header_buckets[0].key);

    var missing_buckets = [_]middleware.RateLimitBucket{.{}};
    var missing_limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 5,
        .key_header = "x-tenant",
        .key_constant = 4,
    }, &missing_buckets);
    var missing_request = Request{};
    var missing_capture = ResponseCapture{};
    _ = try run_rate_limit(&missing_limiter, &missing_request, &missing_capture);
    try std.testing.expectEqual(@as(u64, 4), missing_buckets[0].key);
}

test "rate limit: probe-ready table inserts and finds distinct keys" {
    var buckets = [_]middleware.RateLimitBucket{.{}} ** 64;
    var limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 1000,
        .burst = 4,
        .key_header = "x-tenant",
    }, &buckets);
    try std.testing.expect(limiter.probe_ready);

    var keys: [32][24]u8 = undefined;
    var lengths: [32]usize = undefined;
    for (0..32) |index| {
        const key = try std.fmt.bufPrint(&keys[index], "tenant-{d}", .{index});
        lengths[index] = key.len;
        var request = header_request("x-tenant", key);
        var capture = ResponseCapture{};
        try std.testing.expectEqual(
            support.radix.MiddlewareResult.continue_dispatch,
            try run_rate_limit(&limiter, &request, &capture),
        );
    }

    var occupied: usize = 0;
    for (buckets) |bucket| {
        if (bucket.last_refill_ns != 0) occupied += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), occupied);

    for (0..32) |index| {
        const key = keys[index][0..lengths[index]];
        var request = header_request("x-tenant", key);
        var capture = ResponseCapture{};
        try std.testing.expectEqual(
            support.radix.MiddlewareResult.continue_dispatch,
            try run_rate_limit(&limiter, &request, &capture),
        );
    }
    var occupied_after: usize = 0;
    for (buckets) |bucket| {
        if (bucket.last_refill_ns != 0) occupied_after += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), occupied_after);
}

test "rate limit: fnv1a_64 pins the standard vectors" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), middleware.fnv1a_64(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), middleware.fnv1a_64("a"));
    try std.testing.expectEqual(@as(u64, 0xe71fa2190541574b), middleware.fnv1a_64("abc"));
}

test "rate limit: a full table evicts the oldest bucket and stays bounded" {
    var buckets = [_]middleware.RateLimitBucket{
        .{ .key = 10, .tokens = 1, .last_refill_ns = 500 },
        .{ .key = 20, .tokens = 1, .last_refill_ns = 900 },
    };
    var limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 1000,
        .burst = 16,
        .key_header = "x-tenant",
    }, &buckets);
    try std.testing.expect(!limiter.probe_ready);

    var request = header_request("x-tenant", "tenant-c");
    var capture = ResponseCapture{};
    _ = try run_rate_limit(&limiter, &request, &capture);

    try std.testing.expectEqual(middleware.fnv1a_64("tenant-c"), buckets[0].key);
    try std.testing.expectEqual(@as(u64, 20), buckets[1].key);
    try std.testing.expectEqual(@as(usize, 2), buckets.len);

    // The evicted key starts empty: rotating keys cannot reset a budget.
    try std.testing.expectEqual(@as(u32, 0), buckets[0].tokens);
    var rotating = header_request("x-tenant", "tenant-e");
    var rotating_capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_rate_limit(&limiter, &rotating, &rotating_capture),
    );
    try std.testing.expectEqualStrings("429 Too Many Requests", rotating_capture.status_line());

    var free_buckets = [_]middleware.RateLimitBucket{
        .{ .key = 10, .tokens = 1, .last_refill_ns = 500 },
        .{},
    };
    var free_limiter = middleware.rate_limit(std.testing.io, .{
        .rate_per_second = 1000,
        .key_header = "x-tenant",
    }, &free_buckets);
    var free_request = header_request("x-tenant", "tenant-d");
    var free_capture = ResponseCapture{};
    _ = try run_rate_limit(&free_limiter, &free_request, &free_capture);
    try std.testing.expectEqual(@as(u64, 10), free_buckets[0].key);
    try std.testing.expectEqual(middleware.fnv1a_64("tenant-d"), free_buckets[1].key);
}

test "rate limit: an empty bucket table fails closed" {
    var limiter = middleware.rate_limit(std.testing.io, .{ .rate_per_second = 2 }, &.{});
    var request = Request{};
    var capture = ResponseCapture{};
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.stop,
        try run_rate_limit(&limiter, &request, &capture),
    );
    try std.testing.expectEqualStrings("429 Too Many Requests", capture.status_line());
    try std.testing.expect(std.mem.indexOf(u8, capture.header_bytes(), "Retry-After: 1\r\n") != null);
}

test "rate limit: indexed table evicts exact oldest with lowest-index tie break" {
    var buckets = [_]middleware.RateLimitBucket{
        .{ .key = 10, .tokens = 1, .last_refill_ns = 100 },
        .{ .key = 20, .tokens = 1, .last_refill_ns = 200 },
        .{ .key = 30, .tokens = 1, .last_refill_ns = 100 },
        .{ .key = 40, .tokens = 1, .last_refill_ns = 300 },
    };
    var slots: [8]middleware.RateLimitIndexSlot = [_]middleware.RateLimitIndexSlot{middleware.RateLimitIndexSlot{}} ** 8;
    var links: [4]middleware.RateLimitLink = [_]middleware.RateLimitLink{middleware.RateLimitLink{}} ** 4;
    var table = try middleware.RateLimitTable.init(&buckets, &slots, &links);

    const victim = table.locate(99).?;
    try std.testing.expect(victim.evicted);
    try std.testing.expectEqual(@as(usize, 0), victim.index);
    buckets[0] = .{ .key = 99, .tokens = 0, .last_refill_ns = 1_000 };

    // The next miss must take the remaining timestamp-100 bucket (index 2),
    // not the later timestamp-200 bucket (index 1).
    const second = table.locate(98).?;
    try std.testing.expect(second.evicted);
    try std.testing.expectEqual(@as(usize, 2), second.index);
}

test "rate limit: indexed table keeps 4096 keys bounded and O(1) expected" {
    var buckets = [_]middleware.RateLimitBucket{.{}} ** 4096;
    var slots: [8192]middleware.RateLimitIndexSlot = [_]middleware.RateLimitIndexSlot{middleware.RateLimitIndexSlot{}} ** 8192;
    var links: [4096]middleware.RateLimitLink = [_]middleware.RateLimitLink{middleware.RateLimitLink{}} ** 4096;
    var table = try middleware.RateLimitTable.init(&buckets, &slots, &links);

    for (1..4097) |key| {
        const slot = table.locate(key).?;
        try std.testing.expect(!slot.matched);
        buckets[slot.index] = .{
            .key = @intCast(key),
            .tokens = 1,
            .last_refill_ns = @intCast(key),
        };
    }
    try std.testing.expectEqual(@as(usize, 4096), table.live);

    table.probe_count = 0;
    for (1..4097) |key| {
        const slot = table.locate(key).?;
        try std.testing.expect(slot.matched);
        try std.testing.expectEqual(@as(u64, @intCast(key)), buckets[slot.index].key);
    }
    try std.testing.expect(table.probe_count <= 4096 * 64);

    // Every live key is unique.
    for (buckets, 0..) |bucket, index| {
        if (bucket.last_refill_ns == 0) continue;
        for (buckets[index + 1 ..]) |other| {
            if (other.last_refill_ns == 0) continue;
            try std.testing.expect(bucket.key != other.key);
        }
    }
}

test "rate limit: indexed eviction starts the new key empty" {
    var buckets = [_]middleware.RateLimitBucket{
        .{ .key = 1, .tokens = 3, .last_refill_ns = 100 },
        .{ .key = 2, .tokens = 3, .last_refill_ns = 200 },
    };
    var slots: [4]middleware.RateLimitIndexSlot = [_]middleware.RateLimitIndexSlot{middleware.RateLimitIndexSlot{}} ** 4;
    var links: [2]middleware.RateLimitLink = [_]middleware.RateLimitLink{middleware.RateLimitLink{}} ** 2;
    var table = try middleware.RateLimitTable.init(&buckets, &slots, &links);

    const victim = table.locate(3).?;
    try std.testing.expect(victim.evicted);
    try std.testing.expectEqual(@as(usize, 0), victim.index);
    buckets[victim.index] = .{ .key = 3, .tokens = 0, .last_refill_ns = 300 };
    const again = table.locate(3).?;
    try std.testing.expect(again.matched);
    try std.testing.expectEqual(@as(u32, 0), buckets[again.index].tokens);
}

test "rate limit: empty indexed table fails closed without probing" {
    var buckets: [0]middleware.RateLimitBucket = .{};
    var slots: [0]middleware.RateLimitIndexSlot = .{};
    var links: [0]middleware.RateLimitLink = .{};
    var table = try middleware.RateLimitTable.init(&buckets, &slots, &links);
    try std.testing.expect(table.locate(1) == null);
}

test "rate limit: indexed constructor rejects duplicate or undersized storage" {
    var duplicate = [_]middleware.RateLimitBucket{
        .{ .key = 1, .tokens = 1, .last_refill_ns = 100 },
        .{ .key = 1, .tokens = 1, .last_refill_ns = 200 },
    };
    var slots: [4]middleware.RateLimitIndexSlot = [_]middleware.RateLimitIndexSlot{middleware.RateLimitIndexSlot{}} ** 4;
    var links: [2]middleware.RateLimitLink = [_]middleware.RateLimitLink{middleware.RateLimitLink{}} ** 2;
    try std.testing.expectError(
        error.DuplicateRateLimitKey,
        middleware.RateLimitTable.init(&duplicate, &slots, &links),
    );
    try std.testing.expectError(
        error.InvalidIndexCapacity,
        middleware.RateLimitTable.init(&duplicate, slots[0..2], &links),
    );
}

test "rate limit: indexed handler bounds a full table through the middleware" {
    var buckets = [_]middleware.RateLimitBucket{.{}} ** 8;
    var slots: [16]middleware.RateLimitIndexSlot = [_]middleware.RateLimitIndexSlot{middleware.RateLimitIndexSlot{}} ** 16;
    var links: [8]middleware.RateLimitLink = [_]middleware.RateLimitLink{middleware.RateLimitLink{}} ** 8;
    var limiter = try middleware.rate_limit_indexed(std.testing.io, .{
        .rate_per_second = 1000,
        .burst = 4,
        .key_header = "x-tenant",
    }, &buckets, &slots, &links);
    try std.testing.expect(limiter.table != null);

    var keys: [9][24]u8 = undefined;
    for (0..9) |index| {
        const key = try std.fmt.bufPrint(&keys[index], "tenant-{d}", .{index});
        var request = header_request("x-tenant", key);
        var capture = ResponseCapture{};
        _ = try run_rate_limit(&limiter, &request, &capture);
    }

    var occupied: usize = 0;
    for (buckets) |bucket| {
        if (bucket.last_refill_ns != 0) occupied += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), occupied);
    for (buckets, 0..) |bucket, index| {
        if (bucket.last_refill_ns == 0) continue;
        for (buckets[index + 1 ..]) |other| {
            if (other.last_refill_ns == 0) continue;
            try std.testing.expect(bucket.key != other.key);
        }
    }
}

test "middleware helpers construct" {
    _ = middleware.security_headers(.{});
}
