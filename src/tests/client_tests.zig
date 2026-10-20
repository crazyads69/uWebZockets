//! Client suite: pure HTTP/1.1 response parsing, request writing, loopback
//! transport behavior, and TLS trust handling.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const support = @import("test_support");

const client = support.client;
const http1 = client.http1;
const request_writer = client.request_writer;
const net = std.Io.net;

test "client module is reachable" {
    _ = support.client;
}

const test_response_capacity = 96 * 1024;
const tls_bio_bytes = 16 * 1024;

/// Accumulates raw bytes and drives one parser, mirroring the transport.
const ResponseHarness = struct {
    parser: http1.Parser,
    buffer: [test_response_capacity]u8 = undefined,
    raw_len: usize = 0,

    fn feed(self: *ResponseHarness, data: []const u8) http1.Progress {
        if (data.len > self.buffer.len - self.raw_len) {
            return .{ .failed = .head_too_large };
        }
        @memcpy(self.buffer[self.raw_len..][0..data.len], data);
        self.raw_len += data.len;

        const progress = self.parser.consume(&self.buffer, self.raw_len);
        switch (progress) {
            .need_more => self.raw_len = self.parser.compact(&self.buffer, self.raw_len),
            .complete, .failed => {},
        }
        return progress;
    }

    fn finish(self: *ResponseHarness) http1.Progress {
        return self.parser.finish_eof(&self.buffer, self.raw_len);
    }
};

/// Feeds one complete response and asserts it parses.
fn expect_complete(body_capacity: usize, wire: []const u8) !http1.ResponseView {
    var harness = ResponseHarness{ .parser = http1.Parser.init(body_capacity, false) };
    switch (harness.feed(wire)) {
        .complete => |view| return view,
        .need_more => return error.MissingFinalResponse,
        .failed => return error.ResponseParseFailed,
    }
}

/// Feeds one response and returns its failure, or null when it did not fail.
fn parse_failure(body_capacity: usize, wire: []const u8) ?http1.ParseFailure {
    var harness = ResponseHarness{ .parser = http1.Parser.init(body_capacity, false) };
    switch (harness.feed(wire)) {
        .failed => |failure| return failure,
        .complete, .need_more => return null,
    }
}

test "client parser: parses status line and headers" {
    const view = try expect_complete(
        1024,
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test:  yes  \r\n\r\nhello",
    );
    try std.testing.expectEqual(@as(u16, 200), view.status);
    try std.testing.expectEqualStrings("hello", view.body);
    try std.testing.expectEqual(@as(usize, 2), view.headers.len);
    try std.testing.expectEqualStrings("Content-Length", view.headers[0].name);
    try std.testing.expectEqualStrings("5", view.headers[0].value);
    try std.testing.expectEqualStrings("X-Test", view.headers[1].name);
    try std.testing.expectEqualStrings("yes", view.headers[1].value);
}

test "client parser: accepts an empty reason phrase" {
    const view = try expect_complete(64, "HTTP/1.1 204 \r\n\r\n");
    try std.testing.expectEqual(@as(u16, 204), view.status);
    try std.testing.expectEqual(@as(usize, 0), view.body.len);
}

test "client parser: rejects malformed status lines" {
    const cases = [_][]const u8{
        "HTTP/1.0 200 OK\r\n\r\n",
        "HTTP/1.1 20 OK\r\n\r\n",
        "HTTP/1.1 2000 OK\r\n\r\n",
        "HTTP/1.1  200 OK\r\n\r\n",
        "HTTP/1.1 200OK\r\n\r\n",
        "HTTP/1.1 099 Nope\r\n\r\n",
        "HTTP/1.1 600 Nope\r\n\r\n",
        "HTTP/1.1 200 OK\n\r\n",
    };
    for (cases) |wire| {
        try std.testing.expectEqual(http1.ParseFailure.malformed, parse_failure(64, wire).?);
    }
}

test "client parser: rejects malformed header lines" {
    const cases = [_][]const u8{
        "HTTP/1.1 200 OK\r\nNoColonHere\r\n\r\n",
        "HTTP/1.1 200 OK\r\nBad Name: value\r\n\r\n",
        "HTTP/1.1 200 OK\r\nName: bad\x01value\r\n\r\n",
        "HTTP/1.1 200 OK\r\n: value\r\n\r\n",
    };
    for (cases) |wire| {
        try std.testing.expectEqual(http1.ParseFailure.malformed, parse_failure(64, wire).?);
    }
}

test "client parser: rejects folded continuation lines" {
    try std.testing.expectEqual(
        http1.ParseFailure.malformed,
        parse_failure(64, "HTTP/1.1 200 OK\r\nX-A: one\r\n two\r\n\r\n").?,
    );
}

test "client parser: content-length body spans partial reads" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world";
    var harness = ResponseHarness{ .parser = http1.Parser.init(64, false) };
    var offset: usize = 0;
    while (offset + 3 < wire.len) : (offset += 3) {
        switch (harness.feed(wire[offset .. offset + 3])) {
            .need_more => {},
            .complete => return error.CompletedTooEarly,
            .failed => return error.ResponseParseFailed,
        }
    }
    switch (harness.feed(wire[offset..])) {
        .complete => |view| {
            try std.testing.expectEqualStrings("hello world", view.body);
            try std.testing.expectEqual(@as(u16, 200), view.status);
        },
        .need_more, .failed => return error.MissingFinalResponse,
    }
}

test "client parser: chunked body decodes with trailers" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6;ext=1\r\n world\r\n" ++
        "0\r\nX-Trailer: yes\r\n\r\n";
    const view = try expect_complete(1024, wire);
    try std.testing.expectEqual(@as(u16, 200), view.status);
    try std.testing.expectEqualStrings("hello world", view.body);
}

test "client parser: chunked body survives byte-at-a-time delivery" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";
    var harness = ResponseHarness{ .parser = http1.Parser.init(1024, false) };
    for (wire, 0..) |_, index| {
        switch (harness.feed(wire[index .. index + 1])) {
            .need_more => {},
            .complete => |view| {
                try std.testing.expectEqualStrings("hello world", view.body);
                return;
            },
            .failed => return error.ResponseParseFailed,
        }
    }
    return error.MissingFinalResponse;
}

test "client parser: chunked body survives every two-part split" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n";
    var split: usize = 1;
    while (split < wire.len) : (split += 1) {
        var harness = ResponseHarness{ .parser = http1.Parser.init(1024, false) };
        switch (harness.feed(wire[0..split])) {
            .need_more => {},
            .complete => return error.CompletedTooEarly,
            .failed => return error.EarlyFailure,
        }
        switch (harness.feed(wire[split..])) {
            .complete => |view| {
                if (!std.mem.eql(u8, view.body, "hello!")) return error.WrongBody;
            },
            .need_more => return error.MissingFinalResponse,
            .failed => return error.LateFailure,
        }
    }
}

test "client parser: rejects conflicting framing" {
    try std.testing.expectEqual(
        http1.ParseFailure.conflicting_framing,
        parse_failure(
            1024,
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello",
        ).?,
    );
    try std.testing.expectEqual(
        http1.ParseFailure.conflicting_framing,
        parse_failure(
            1024,
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
        ).?,
    );
}

test "client parser: rejects unsupported transfer codings" {
    try std.testing.expectEqual(
        http1.ParseFailure.unsupported_transfer_encoding,
        parse_failure(1024, "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n").?,
    );
}

test "client parser: skips an unsolicited 100 and rejects other interim codes" {
    const view = try expect_complete(
        64,
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n",
    );
    try std.testing.expectEqual(@as(u16, 204), view.status);

    const with_headers = try expect_complete(
        64,
        "HTTP/1.1 100 Continue\r\nX-Info: pending\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    );
    try std.testing.expectEqualStrings("ok", with_headers.body);

    try std.testing.expectEqual(
        http1.ParseFailure.unexpected_interim,
        parse_failure(64, "HTTP/1.1 101 Switching Protocols\r\n\r\n").?,
    );
    try std.testing.expectEqual(
        http1.ParseFailure.unexpected_interim,
        parse_failure(64, "HTTP/1.1 103 Early Hints\r\n\r\n").?,
    );
}

test "client parser: enforces head and field bounds" {
    var oversized: [http1.max_head_bytes + 32]u8 = undefined;
    @memcpy(oversized[0.."HTTP/1.1 200 OK\r\nX-Big: ".len], "HTTP/1.1 200 OK\r\nX-Big: ");
    @memset(oversized["HTTP/1.1 200 OK\r\nX-Big: ".len..], 'a');
    try std.testing.expectEqual(
        http1.ParseFailure.head_too_large,
        parse_failure(64, &oversized).?,
    );

    var fields: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&fields);
    try writer.writeAll("HTTP/1.1 200 OK\r\n");
    for (0..http1.max_header_fields + 1) |index| {
        try writer.print("X-{d}: v\r\n", .{index});
    }
    try writer.writeAll("\r\n");
    try std.testing.expectEqual(
        http1.ParseFailure.too_many_headers,
        parse_failure(64, writer.buffered()).?,
    );
}

test "client parser: enforces body capacity" {
    try std.testing.expectEqual(
        http1.ParseFailure.body_too_large,
        parse_failure(8, "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n123456789").?,
    );
    try std.testing.expectEqual(
        http1.ParseFailure.body_too_large,
        parse_failure(
            8,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n",
        ).?,
    );
}

test "client parser: head requests ignore a large content length" {
    var parser = http1.Parser.init(64, true);
    var buffer: [256]u8 = undefined;
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 512\r\n\r\n";
    @memcpy(buffer[0..wire.len], wire);
    switch (parser.consume(&buffer, wire.len)) {
        .complete => |view| try std.testing.expectEqual(@as(usize, 0), view.body.len),
        .need_more, .failed => return error.MissingFinalResponse,
    }
}

test "client parser: no-body statuses complete with empty bodies" {
    const view = try expect_complete(64, "HTTP/1.1 304 Not Modified\r\nContent-Length: 512\r\n\r\n");
    try std.testing.expectEqual(@as(usize, 0), view.body.len);
}

test "client parser: eof-delimited body completes at close" {
    var harness = ResponseHarness{ .parser = http1.Parser.init(64, false) };
    switch (harness.feed("HTTP/1.1 200 OK\r\nX-Test: yes\r\n\r\npartial body")) {
        .need_more => {},
        .complete, .failed => return error.UnexpectedParseResult,
    }
    switch (harness.finish()) {
        .complete => |view| {
            try std.testing.expectEqualStrings("partial body", view.body);
            try std.testing.expectEqual(@as(u16, 200), view.status);
        },
        .need_more, .failed => return error.MissingFinalResponse,
    }
}

test "client parser: copies a view into caller storage" {
    const view = try expect_complete(64, "HTTP/1.1 201 Created\r\nX-A: one\r\nContent-Length: 4\r\n\r\ndone");
    var headers: [http1.max_header_fields]client.Header = undefined;
    var head: [http1.max_head_bytes]u8 = undefined;
    var body: [64]u8 = undefined;
    const copied = try http1.copy_view(view, &headers, &head, &body);
    try std.testing.expectEqual(@as(u16, 201), copied.status);
    try std.testing.expectEqualStrings("done", copied.body);
    try std.testing.expectEqualStrings("X-A", copied.headers[0].name);
    try std.testing.expectEqualStrings("one", copied.headers[0].value);
}

test "client request: formats an origin-form head" {
    const headers = [_]client.Header{.{ .name = "Accept", .value = "text/plain" }};
    const request = client.Request{
        .method = .post,
        .host = "127.0.0.1",
        .path = "/submit?x=1",
        .headers = &headers,
        .body = "abc",
    };
    var buffer: [512]u8 = undefined;
    const head = try request_writer.write_head(request, .{ .port = 8080, .tls = false }, &buffer);
    try std.testing.expectEqualStrings(
        "POST /submit?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 3\r\nConnection: close\r\nAccept: text/plain\r\n\r\n",
        head,
    );
}

test "client request: brackets IPv6 hosts and omits default ports" {
    var buffer: [256]u8 = undefined;
    const secure = try request_writer.write_head(
        .{ .method = .get, .host = "::1", .path = "/" },
        .{ .port = 443, .tls = true },
        &buffer,
    );
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: [::1]\r\nConnection: close\r\n\r\n", secure);

    const plain = try request_writer.write_head(
        .{ .method = .query, .host = "127.0.0.1", .path = "/lookup" },
        .{ .port = 80, .tls = false },
        &buffer,
    );
    try std.testing.expectEqualStrings("QUERY /lookup HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", plain);

    const trace = try request_writer.write_head(
        .{ .method = .trace, .host = "127.0.0.1", .path = "/probe" },
        .{ .port = 80, .tls = false },
        &buffer,
    );
    try std.testing.expectEqualStrings("TRACE /probe HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", trace);
}

test "client request: rejects reserved and malformed fields" {
    const reserved = [_]client.Header{.{ .name = "Content-Length", .value = "9" }};
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(
        error.ReservedHeader,
        request_writer.write_head(.{ .host = "127.0.0.1", .headers = &reserved }, .{ .port = 80, .tls = false }, &buffer),
    );

    const invalid_name = [_]client.Header{.{ .name = "Bad Name", .value = "v" }};
    try std.testing.expectError(
        error.InvalidHeaderName,
        request_writer.write_head(.{ .host = "127.0.0.1", .headers = &invalid_name }, .{ .port = 80, .tls = false }, &buffer),
    );

    const invalid_value = [_]client.Header{.{ .name = "X-A", .value = "bad\nvalue" }};
    try std.testing.expectError(
        error.InvalidHeaderValue,
        request_writer.write_head(.{ .host = "127.0.0.1", .headers = &invalid_value }, .{ .port = 80, .tls = false }, &buffer),
    );

    try std.testing.expectError(
        error.InvalidPath,
        request_writer.write_head(.{ .host = "127.0.0.1", .path = "no-slash" }, .{ .port = 80, .tls = false }, &buffer),
    );
}

/// Publishes the ephemeral listener port to the test thread.
const PortSlot = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    fn publish(self: *PortSlot, port: u16) void {
        self.port.store(port, .release);
        self.ready.store(true, .release);
    }

    fn wait(self: *PortSlot) u16 {
        while (!self.ready.load(.acquire)) std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
            .awake,
        ) catch {};
        return self.port.load(.acquire);
    }
};

/// Writes every byte, returning false on any transport failure.
fn write_all(io: std.Io, handle: net.Socket.Handle, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        // The trailing pattern slice is not written because `splat` is zero.
        const written = io.vtable.netWrite(io.userdata, handle, bytes[offset..], &.{""}, 0) catch return false;
        if (written == 0) return false;
        offset += written;
    }
    return true;
}

/// Reads one request head; returns false when the peer fails or closes early.
fn read_request_head(io: std.Io, handle: net.Socket.Handle) bool {
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        var data = [1][]u8{buffer[total..]};
        const read = io.vtable.netRead(io.userdata, handle, &data) catch return false;
        if (read == 0) return false;
        total += read;
        if (std.mem.indexOf(u8, buffer[0..total], "\r\n\r\n") != null) return true;
    }
    return false;
}

/// Best-effort receive timeout so a failed test cannot block join forever.
///
/// Windows has no portable `timeval` socket option here; every test that
/// spawns a peer connects before asserting, so the listener does not block.
fn set_accept_timeout(handle: net.Socket.Handle) void {
    if (builtin.os.tag == .windows) return;
    var timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(
        handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
}

/// Binds an ephemeral listener and publishes its port.
fn listen_loopback(port_slot: *PortSlot) ?net.Server {
    const io = std.testing.io;
    var address = net.IpAddress.parse("127.0.0.1", 0) catch return null;
    var server = address.listen(io, .{}) catch return null;
    set_accept_timeout(server.socket.handle);
    port_slot.publish(server.socket.address.getPort());
    return server;
}

/// Serves one canned response, then half-closes.
const PlainServer = struct {
    port_slot: *PortSlot,
    response: []const u8,

    fn run(self: *PlainServer) void {
        const io = std.testing.io;
        var server = listen_loopback(self.port_slot) orelse return;
        defer server.deinit(io);

        var stream = server.accept(io) catch return;
        defer stream.close(io);
        if (!read_request_head(io, stream.socket.handle)) return;
        _ = write_all(io, stream.socket.handle, self.response);
        // The response is complete; a failed half-close cannot change it.
        stream.shutdown(io, .send) catch {};
    }
};

/// Holds one accepted connection open until the test releases it.
const StallServer = struct {
    port_slot: *PortSlot,
    stop: *std.atomic.Value(bool),

    fn run(self: *StallServer) void {
        const io = std.testing.io;
        var server = listen_loopback(self.port_slot) orelse return;
        defer server.deinit(io);

        var stream = server.accept(io) catch return;
        defer stream.close(io);
        while (!self.stop.load(.acquire)) std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms),
            .awake,
        ) catch {};
    }
};

/// Test-only CA and leaf generated with BoringSSL.
const TestPki = struct {
    ca_cert: *c.X509,
    ca_key: *c.EVP_PKEY,
    leaf_cert: *c.X509,
    leaf_key: *c.EVP_PKEY,

    fn deinit(self: *TestPki) void {
        c.X509_free(self.leaf_cert);
        c.EVP_PKEY_free(self.leaf_key);
        c.X509_free(self.ca_cert);
        c.EVP_PKEY_free(self.ca_key);
        self.* = undefined;
    }
};

/// Generates a P-256 CA and a localhost leaf signed by it.
fn generate_test_pki() !TestPki {
    const ca_key = try generate_p256_key();
    errdefer c.EVP_PKEY_free(ca_key);
    const ca_cert = c.X509_new() orelse return error.CertificateFailed;
    errdefer c.X509_free(ca_cert);

    try set_certificate_fields(ca_cert);
    try add_extension(ca_cert, c.NID_basic_constraints, "critical,CA:TRUE");
    try add_extension(ca_cert, c.NID_key_usage, "critical,keyCertSign,cRLSign");
    try add_subject_name(ca_cert, "uWebZockets test CA");
    if (c.X509_set_issuer_name(ca_cert, c.X509_get_subject_name(ca_cert)) != 1) {
        return error.CertificateFailed;
    }
    if (c.X509_set_pubkey(ca_cert, ca_key) != 1) return error.CertificateFailed;
    if (c.X509_sign(ca_cert, ca_key, c.EVP_sha256()) == 0) return error.CertificateFailed;

    const leaf_key = try generate_p256_key();
    errdefer c.EVP_PKEY_free(leaf_key);
    const leaf_cert = c.X509_new() orelse return error.CertificateFailed;
    errdefer c.X509_free(leaf_cert);

    try set_certificate_fields(leaf_cert);
    try add_extension(leaf_cert, c.NID_basic_constraints, "critical,CA:FALSE");
    try add_extension(leaf_cert, c.NID_key_usage, "critical,digitalSignature");
    try add_extension(leaf_cert, c.NID_ext_key_usage, "serverAuth");
    try add_extension(leaf_cert, c.NID_subject_alt_name, "DNS:localhost, IP:127.0.0.1");
    try add_subject_name(leaf_cert, "localhost");
    if (c.X509_set_issuer_name(leaf_cert, c.X509_get_subject_name(ca_cert)) != 1) {
        return error.CertificateFailed;
    }
    if (c.X509_set_pubkey(leaf_cert, leaf_key) != 1) return error.CertificateFailed;
    if (c.X509_sign(leaf_cert, ca_key, c.EVP_sha256()) == 0) return error.CertificateFailed;

    return .{
        .ca_cert = ca_cert,
        .ca_key = ca_key,
        .leaf_cert = leaf_cert,
        .leaf_key = leaf_key,
    };
}

fn generate_p256_key() !*c.EVP_PKEY {
    const keygen = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null) orelse return error.KeyFailed;
    defer c.EVP_PKEY_CTX_free(keygen);
    if (c.EVP_PKEY_keygen_init(keygen) != 1) return error.KeyFailed;
    if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(keygen, c.NID_X9_62_prime256v1) != 1) {
        return error.KeyFailed;
    }
    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(keygen, &key) != 1) return error.KeyFailed;
    return key orelse error.KeyFailed;
}

fn set_certificate_fields(certificate: *c.X509) !void {
    if (c.X509_set_version(certificate, 2) != 1) return error.CertificateFailed;
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(certificate), 1) != 1) {
        return error.CertificateFailed;
    }
    if (c.X509_gmtime_adj(c.X509_getm_notBefore(certificate), -3600) == null) {
        return error.CertificateFailed;
    }
    if (c.X509_gmtime_adj(c.X509_getm_notAfter(certificate), 90 * 24 * 3600) == null) {
        return error.CertificateFailed;
    }
}

fn add_subject_name(certificate: *c.X509, common_name: []const u8) !void {
    const subject = c.X509_get_subject_name(certificate) orelse return error.CertificateFailed;
    if (c.X509_NAME_add_entry_by_txt(
        subject,
        "CN",
        c.MBSTRING_UTF8,
        common_name.ptr,
        @intCast(common_name.len),
        -1,
        0,
    ) != 1) return error.CertificateFailed;
}

fn add_extension(certificate: *c.X509, nid: c_int, value: [*:0]const u8) !void {
    const extension = c.X509V3_EXT_nconf_nid(null, null, nid, value) orelse {
        return error.CertificateFailed;
    };
    defer c.X509_EXTENSION_free(extension);
    if (c.X509_add_ext(certificate, extension, -1) != 1) return error.CertificateFailed;
}

/// Serves one canned response over TLS using an ephemeral or PKI certificate.
const TlsServer = struct {
    port_slot: *PortSlot,
    response: []const u8,
    ca_path: ?[:0]const u8,
    pki: ?*TestPki = null,
    /// Pins the test server to TLS 1.2 so the client's TLS 1.3 floor is tested.
    tls12_only: bool = false,

    fn run(self: *TlsServer) void {
        const io = std.testing.io;
        if (self.pki) |pki| {
            const context = c.SSL_CTX_new(c.TLS_server_method()) orelse return;
            defer c.SSL_CTX_free(context);
            if (self.tls12_only) {
                if (c.SSL_CTX_set_min_proto_version(context, c.TLS1_2_VERSION) != 1) return;
                if (c.SSL_CTX_set_max_proto_version(context, c.TLS1_2_VERSION) != 1) return;
            }
            if (c.SSL_CTX_use_certificate(context, pki.leaf_cert) != 1) return;
            if (c.SSL_CTX_use_PrivateKey(context, pki.leaf_key) != 1) return;
            if (c.SSL_CTX_check_private_key(context) != 1) return;
            if (self.ca_path) |path| {
                if (!write_certificate_pem(io, pki.ca_cert, path)) return;
            }
            self.serve(io, context);
            return;
        }

        var context = support.tls.TlsContext.init_ephemeral(.{}) catch return;
        defer context.deinit();
        self.serve(io, context.ctx);
    }

    fn serve(self: *TlsServer, io: std.Io, context: *c.SSL_CTX) void {
        var server = listen_loopback(self.port_slot) orelse return;
        defer server.deinit(io);

        var stream = server.accept(io) catch return;
        defer stream.close(io);
        serve_tls(io, stream.socket.handle, context, self.response) catch {};
    }
};

/// Writes one certificate as a PEM trust anchor.
fn write_certificate_pem(io: std.Io, certificate: *c.X509, path: [:0]const u8) bool {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return false;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_X509(bio, certificate) != 1) return false;

    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (c.BIO_ctrl_pending(bio) > 0 and total < buffer.len) {
        const read = c.BIO_read(bio, buffer[total..].ptr, @intCast(buffer.len - total));
        if (read <= 0) return false;
        total += @intCast(read);
    }

    var file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    file.writeStreamingAll(io, buffer[0..total]) catch return false;
    return true;
}

/// Drains ciphertext from a BIO to the socket.
fn bio_flush(io: std.Io, handle: net.Socket.Handle, outgoing: *c.BIO) bool {
    var buffer: [tls_bio_bytes]u8 = undefined;
    while (c.BIO_ctrl_pending(outgoing) > 0) {
        const pending: usize = @intCast(c.BIO_ctrl_pending(outgoing));
        const read = c.BIO_read(outgoing, &buffer, @intCast(@min(pending, buffer.len)));
        if (read <= 0) return false;
        if (!write_all(io, handle, buffer[0..@intCast(read)])) return false;
    }
    return true;
}

/// Reads ciphertext from the socket into a BIO.
fn bio_fill(io: std.Io, handle: net.Socket.Handle, incoming: *c.BIO) bool {
    var buffer: [tls_bio_bytes]u8 = undefined;
    var data = [1][]u8{&buffer};
    const read = io.vtable.netRead(io.userdata, handle, &data) catch return false;
    if (read == 0) return false;

    var offset: usize = 0;
    while (offset < read) {
        const written = c.BIO_write(incoming, buffer[offset..].ptr, @intCast(read - offset));
        if (written <= 0) return false;
        offset += @intCast(written);
    }
    return true;
}

/// Serves one request/response exchange on a blocking memory-BIO session.
fn serve_tls(
    io: std.Io,
    handle: net.Socket.Handle,
    ctx: *c.SSL_CTX,
    response: []const u8,
) !void {
    const ssl = c.SSL_new(ctx) orelse return error.SslCreationFailed;
    defer c.SSL_free(ssl);

    var ssl_bio: ?*c.BIO = null;
    var network_bio: ?*c.BIO = null;
    if (c.BIO_new_bio_pair(&ssl_bio, tls_bio_bytes, &network_bio, tls_bio_bytes) != 1) {
        return error.BioCreationFailed;
    }
    defer {
        if (network_bio) |bio| _ = c.BIO_free(bio);
    }
    c.SSL_set_bio(ssl, ssl_bio.?, ssl_bio.?);
    c.SSL_set_accept_state(ssl);

    var rounds: usize = 0;
    while (c.SSL_is_init_finished(ssl) == 0 and rounds < 64) : (rounds += 1) {
        const result = c.SSL_do_handshake(ssl);
        const ssl_error = c.SSL_get_error(ssl, result);
        switch (ssl_error) {
            c.SSL_ERROR_NONE, c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {},
            else => return error.HandshakeFailed,
        }
        if (!bio_flush(io, handle, network_bio.?)) return error.HandshakeIoFailed;
        if (ssl_error == c.SSL_ERROR_WANT_READ and !bio_fill(io, handle, network_bio.?)) {
            return error.HandshakeIoFailed;
        }
    }
    if (c.SSL_is_init_finished(ssl) != 1) return error.HandshakeStalled;

    var request: [4096]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request.len) {
        const read = c.SSL_read(ssl, request[request_len..].ptr, @intCast(request.len - request_len));
        if (read > 0) {
            request_len += @intCast(read);
            if (std.mem.indexOf(u8, request[0..request_len], "\r\n\r\n") != null) break;
            continue;
        }
        const ssl_error = c.SSL_get_error(ssl, read);
        if (ssl_error != c.SSL_ERROR_WANT_READ and ssl_error != c.SSL_ERROR_WANT_WRITE) {
            return error.RequestReadFailed;
        }
        if (!bio_flush(io, handle, network_bio.?)) return error.RequestReadFailed;
        if (!bio_fill(io, handle, network_bio.?)) return error.RequestReadFailed;
    }
    if (std.mem.indexOf(u8, request[0..request_len], "\r\n\r\n") == null) {
        return error.RequestTooLarge;
    }

    var written_total: usize = 0;
    while (written_total < response.len) {
        const written = c.SSL_write(ssl, response[written_total..].ptr, @intCast(response.len - written_total));
        if (written > 0) {
            written_total += @intCast(written);
            if (!bio_flush(io, handle, network_bio.?)) return error.ResponseWriteFailed;
            continue;
        }
        const ssl_error = c.SSL_get_error(ssl, written);
        if (ssl_error != c.SSL_ERROR_WANT_WRITE and ssl_error != c.SSL_ERROR_WANT_READ) {
            return error.ResponseWriteFailed;
        }
        if (!bio_flush(io, handle, network_bio.?)) return error.ResponseWriteFailed;
        if (!bio_fill(io, handle, network_bio.?)) return error.ResponseWriteFailed;
    }
    if (!bio_flush(io, handle, network_bio.?)) return error.ResponseWriteFailed;
}

test "client: fetches a content-length response over loopback" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nX-Test: yes\r\n\r\nhello world";
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = wire };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = port, .read_timeout_ms = 5_000 },
        &storage,
    );

    switch (outcome) {
        .response => |view| {
            try std.testing.expectEqual(@as(u16, 200), view.status);
            try std.testing.expectEqualStrings("hello world", view.body);
            try std.testing.expectEqual(@as(usize, 2), view.headers.len);
            try std.testing.expectEqualStrings("X-Test", view.headers[1].name);
            try std.testing.expectEqualStrings("yes", view.headers[1].value);
        },
        .failure => return error.FetchFailed,
    }
}

test "client: fetches a chunked response over loopback" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "1\r\n!\r\n" ++
        "0\r\n\r\n";
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = wire };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/chunked" },
        .{ .port = port, .read_timeout_ms = 5_000 },
        &storage,
    );

    switch (outcome) {
        .response => |view| try std.testing.expectEqualStrings("hello!", view.body),
        .failure => return error.FetchFailed,
    }
}

test "client: reports a protocol failure for a malformed response" {
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = "GARBAGE\r\n\r\n" };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = port, .read_timeout_ms = 5_000 },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.protocol, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: reports closed when the peer truncates the body" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc";
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = wire };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = port, .read_timeout_ms = 5_000 },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.closed, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: times out a stalled response" {
    var port_slot = PortSlot{};
    var stop = std.atomic.Value(bool).init(false);
    var server = StallServer{ .port_slot = &port_slot, .stop = &stop };
    const thread = try std.Thread.spawn(.{}, StallServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = port, .read_timeout_ms = 50 },
        &storage,
    );
    stop.store(true, .release);

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.timeout, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: rejects a fetch when inflight capacity is reached" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = wire };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    var instance = try client.client(1).init(std.testing.io);
    defer instance.deinit();

    var capture = OutcomeCapture{};
    const request = client.Request{ .method = .get, .host = "127.0.0.1", .path = "/" };
    const options = client.FetchOptions{ .port = port_slot.wait(), .read_timeout_ms = 5_000 };
    try instance.fetch(request, options, &capture, OutcomeCapture.on_outcome);
    try std.testing.expectError(
        error.InflightCapacityReached,
        instance.fetch(request, options, &capture, OutcomeCapture.on_outcome),
    );
    try instance.run();
    try std.testing.expect(capture.completed);
    switch (capture.outcome) {
        .response => |view| try std.testing.expectEqualStrings("ok", view.body),
        .failure => return error.FetchFailed,
    }
}

test "client: tls verification without a ca path fails closed" {
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = 443,
            .tls = .{ .verify = true, .ca_path = null, .server_name = "localhost" },
        },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.tls, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: tls verification without a ca path returns the named error" {
    var instance = try client.client(1).init(std.testing.io);
    defer instance.deinit();

    var capture = OutcomeCapture{};
    try std.testing.expectError(
        error.CaPathRequired,
        instance.fetch(
            .{ .method = .get, .host = "127.0.0.1", .path = "/" },
            .{
                .port = 443,
                .tls = .{ .verify = true, .ca_path = null, .server_name = "localhost" },
            },
            &capture,
            OutcomeCapture.on_outcome,
        ),
    );
    try std.testing.expect(!capture.completed);
}

test "client: tls verification rejects an untrusted trust anchor" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const ca_path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &directory.sub_path, "untrusted-ca.pem" },
    );
    defer std.testing.allocator.free(ca_path);

    var serving_pki = try generate_test_pki();
    defer serving_pki.deinit();
    var untrusted_pki = try generate_test_pki();
    defer untrusted_pki.deinit();
    try std.testing.expect(write_certificate_pem(std.testing.io, untrusted_pki.ca_cert, ca_path));

    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var port_slot = PortSlot{};
    var server = TlsServer{ .port_slot = &port_slot, .response = wire, .ca_path = null, .pki = &serving_pki };
    const thread = try std.Thread.spawn(.{}, TlsServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = port,
            .tls = .{ .verify = true, .ca_path = ca_path, .server_name = "localhost" },
            .read_timeout_ms = 5_000,
        },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.tls, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: tls verification rejects the wrong server name" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const ca_path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &directory.sub_path, "ca.pem" },
    );
    defer std.testing.allocator.free(ca_path);

    var pki = try generate_test_pki();
    defer pki.deinit();
    try std.testing.expect(write_certificate_pem(std.testing.io, pki.ca_cert, ca_path));

    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var port_slot = PortSlot{};
    var server = TlsServer{ .port_slot = &port_slot, .response = wire, .ca_path = null, .pki = &pki };
    const thread = try std.Thread.spawn(.{}, TlsServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = port,
            .tls = .{ .verify = true, .ca_path = ca_path, .server_name = "not-localhost" },
            .read_timeout_ms = 5_000,
        },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.tls, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: rejects a tls 1.2 only server" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const ca_path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &directory.sub_path, "ca.pem" },
    );
    defer std.testing.allocator.free(ca_path);

    var pki = try generate_test_pki();
    defer pki.deinit();

    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var port_slot = PortSlot{};
    var server = TlsServer{
        .port_slot = &port_slot,
        .response = wire,
        .ca_path = ca_path,
        .pki = &pki,
        .tls12_only = true,
    };
    const thread = try std.Thread.spawn(.{}, TlsServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = port,
            .tls = .{ .verify = true, .ca_path = ca_path, .server_name = "localhost" },
            .read_timeout_ms = 5_000,
        },
        &storage,
    );

    switch (outcome) {
        .failure => |failure| try std.testing.expectEqual(client.FailureKind.tls, failure.kind),
        .response => return error.UnexpectedResponse,
    }
}

test "client: a failed fetch releases its slot for reuse" {
    var instance = try client.client(1).init(std.testing.io);
    defer instance.deinit();

    var refused = OutcomeCapture{};
    try instance.fetch(
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = 1, .connect_timeout_ms = 200, .read_timeout_ms = 200 },
        &refused,
        OutcomeCapture.on_outcome,
    );
    try instance.run();
    try std.testing.expect(refused.completed);
    try std.testing.expectEqual(client.FailureKind.connect, refused.outcome.failure.kind);

    // The same single-slot client must accept and complete a second request.
    const wire = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    var port_slot = PortSlot{};
    var server = PlainServer{ .port_slot = &port_slot, .response = wire };
    const thread = try std.Thread.spawn(.{}, PlainServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var accepted = OutcomeCapture{};
    try instance.fetch(
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{ .port = port, .read_timeout_ms = 5_000 },
        &accepted,
        OutcomeCapture.on_outcome,
    );
    try instance.run();
    try std.testing.expect(accepted.completed);
    try std.testing.expectEqual(@as(u16, 204), accepted.outcome.response.status);
}

/// Records one outcome for callback-based tests.
const OutcomeCapture = struct {
    outcome: client.FetchOutcome = .{ .failure = .{ .kind = .closed, .message = "pending" } },
    completed: bool = false,

    fn on_outcome(context: *anyopaque, outcome: client.FetchOutcome) void {
        const self: *OutcomeCapture = @ptrCast(@alignCast(context));
        self.outcome = outcome;
        self.completed = true;
    }
};

test "client: fetches over tls without verification" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var port_slot = PortSlot{};
    var server = TlsServer{ .port_slot = &port_slot, .response = wire, .ca_path = null };
    const thread = try std.Thread.spawn(.{}, TlsServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = port,
            .tls = .{ .verify = false, .ca_path = null, .server_name = "localhost" },
            .read_timeout_ms = 5_000,
        },
        &storage,
    );

    switch (outcome) {
        .response => |view| {
            try std.testing.expectEqual(@as(u16, 200), view.status);
            try std.testing.expectEqualStrings("hello", view.body);
        },
        .failure => return error.FetchFailed,
    }
}

test "client: fetches over tls with a generated trust anchor" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const ca_path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &directory.sub_path, "ca.pem" },
    );
    defer std.testing.allocator.free(ca_path);

    var pki = try generate_test_pki();
    defer pki.deinit();

    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var port_slot = PortSlot{};
    var server = TlsServer{ .port_slot = &port_slot, .response = wire, .ca_path = ca_path, .pki = &pki };
    const thread = try std.Thread.spawn(.{}, TlsServer.run, .{&server});
    defer thread.join();

    const port = port_slot.wait();
    var storage = client.FetchStorage{};
    const outcome = try client.fetch_blocking(
        std.testing.io,
        .{ .method = .get, .host = "127.0.0.1", .path = "/" },
        .{
            .port = port,
            .tls = .{ .verify = true, .ca_path = ca_path, .server_name = "localhost" },
            .read_timeout_ms = 5_000,
        },
        &storage,
    );

    switch (outcome) {
        .response => |view| {
            try std.testing.expectEqual(@as(u16, 200), view.status);
            try std.testing.expectEqualStrings("hello", view.body);
        },
        .failure => return error.FetchFailed,
    }
}
