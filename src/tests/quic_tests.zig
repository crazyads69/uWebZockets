const std = @import("std");
const c = @import("c");
const support = @import("test_support");
const api = support.quic_api;
const engine = support.quic_engine;
const packet = support.quic_packet;
const stream = support.quic_stream;
const validation = support.quic_validation;
const datagram_ring = support.datagram_ring;
const HeaderSet = stream.HeaderSet;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const StreamStatus = support.http_response.StreamStatus;

test "quic: packet inspector parses v1 and v2 long headers" {
    const v1_initial =
        "\xc0\x00\x00\x00\x01" ++
        "\x08destinat" ++
        "\x00" ++
        "\x00" ++
        "\x01\xaa";
    const initial = try packet.inspect_packet(v1_initial);
    try std.testing.expectEqual(packet.PacketKind.initial, initial.kind);
    try std.testing.expectEqualStrings("destinat", initial.destination_id);
    try std.testing.expectEqual(@as(usize, v1_initial.len), initial.packet_length);
    try std.testing.expectEqualSlices(u8, "\xaa", initial.payload);

    const v2_initial =
        "\xd0\x6b\x33\x43\xcf" ++
        "\x00\x00" ++
        "\x00" ++
        "\x01\xbb";
    const initial_v2 = try packet.inspect_packet(v2_initial);
    try std.testing.expectEqual(packet.PacketKind.initial, initial_v2.kind);
    try std.testing.expectEqual(@as(u32, 0x6b3343cf), initial_v2.version);
}

test "quic: packet inspector bounds connection ids, varints, and versions" {
    const negotiation =
        "\x80\x00\x00\x00\x00" ++
        "\x00\x00" ++
        "\x00\x00\x00\x01";
    const header = try packet.inspect_packet(negotiation);
    try std.testing.expectEqual(packet.PacketKind.version_negotiation, header.kind);

    try std.testing.expectError(
        error.InvalidConnectionIdLength,
        packet.inspect_packet("\xc0\x00\x00\x00\x01\x15x"),
    );
    try std.testing.expectError(
        error.TruncatedPacket,
        packet.inspect_packet("\xc0\x00\x00\x00\x01\x00\x00\x40"),
    );
    try std.testing.expectError(
        error.InvalidVersionNegotiation,
        packet.inspect_packet("\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
    );
}

test "quic: sockaddr conversion preserves address family and port" {
    const input = try std.Io.net.IpAddress.parse("127.0.0.1", 8443);
    const address = api.Sockaddr.init(input);
    const sockaddr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&address.storage));

    try std.testing.expectEqual(std.posix.AF.INET, sockaddr.family);
    try std.testing.expectEqual(@as(u16, 8443), std.mem.bigToNative(u16, sockaddr.port));
    try std.testing.expectEqual(@as(c.socklen_t, @sizeOf(std.posix.sockaddr.in)), address.length);
}

test "quic: engine policy pins BBR congestion control and pacing" {
    const TestEngine = engine.quic_engine(2, 1024, 0, stream.default_capacities);
    var settings: c.lsquic_engine_settings = std.mem.zeroes(c.lsquic_engine_settings);
    TestEngine.apply_settings(&settings);

    var settings_error: [256]u8 = undefined;
    const accepted = c.lsquic_engine_check_settings(
        &settings,
        c.LSENG_HTTP_SERVER,
        &settings_error,
        settings_error.len,
    );

    try std.testing.expectEqual(@as(c_int, 0), accepted);
    try std.testing.expectEqual(@as(c_uint, 2), settings.es_cc_algo);
    try std.testing.expectEqual(@as(c_int, 1), settings.es_pace_packets);
    try std.testing.expectEqual(@as(c_uint, 2), settings.es_max_streams_in);
}

test "quic: idle engine service delay is capped at one second" {
    const TestEngine = engine.quic_engine(2, 64, 0, stream.default_capacities);
    var quic_engine = try TestEngine.init();
    defer quic_engine.deinit();

    // An unstarted engine has no advance tick; the timer must not poll at 50 ms.
    try std.testing.expectEqual(@as(u64, 1000), quic_engine.next_timeout_ms());
}

test "quic: each live stream reserves independent request and trailer header slots" {
    const TestEngine = engine.quic_engine(2, 64, 0, stream.default_capacities);
    var quic_engine = try TestEngine.init();
    defer quic_engine.deinit();

    try std.testing.expectEqual(@as(usize, 4), quic_engine.header_pool.free_count);
    try std.testing.expectEqual(
        @as(usize, 4 * stream.header_capacity),
        quic_engine.header_storage.len,
    );
}

test "quic: bounded header set validates pseudo headers and framing" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/hello?name=zig"));
    try std.testing.expect(add_test_header(&header_set, "content-length", "4"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("/hello", header_set.request.path);
    try std.testing.expectEqualStrings("name=zig", header_set.request.query);
    try std.testing.expectEqual(@as(?usize, 4), header_set.content_length);
    try std.testing.expectEqualStrings("localhost", header_set.request.get_header("host").?);
}

test "quic: engine rejects request header storage above u16 field lengths" {
    const TestEngine = engine.quic_engine(2, 1024, 0, .{
        .request_header_size = std.math.maxInt(u16) + 1,
    });
    try std.testing.expectError(error.InvalidHttp3Capacity, TestEngine.init());
}

test "quic: header set rejects decoded storage exhaustion" {
    var storage: [32]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(add_test_header(&header_set, "x-name", "0123456789"));
    try std.testing.expect(header_set.prepare_decode(null, header_set.storage.len) == null);
    try std.testing.expect(header_set.prepare_decode(null, 1) != null);
}

test "quic: HTTP/3 QUERY exposes invalid media type before dispatch" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(add_test_header(&header_set, ":method", "QUERY"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/query"));
    try std.testing.expect(add_test_header(
        &header_set,
        "content-type",
        "text/plain; charset=",
    ));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expect(!header_set.request.valid_query_content_type());
}

test "quic: header set rejects forbidden connection metadata" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(!add_test_header(&header_set, "connection", "close"));
    try std.testing.expect(!validation.valid_target("/path#fragment"));
    try std.testing.expect(validation.parse_decimal("184467440737095516160") == null);

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "*"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "OPTIONS"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "*"));
    try std.testing.expect(header_set.process_header(null));
}

test "quic: HTTP/3 regular CONNECT requires authority and omits scheme and path" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("localhost:443", header_set.request.target);
    try std.testing.expectEqualStrings("", header_set.request.path);
    try std.testing.expectEqualStrings("localhost:443", header_set.request.get_header("host").?);

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/tunnel"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":protocol", "websocket"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":protocol", "websocket"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/tunnel"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("/tunnel", header_set.request.target);
    try std.testing.expectEqualStrings("websocket", header_set.protocol.?);
}

test "quic: HTTP/3 rejects :protocol outside extended CONNECT" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;

    // A regular request carrying :protocol is malformed (RFC 9220).
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/"));
    try std.testing.expect(add_test_header(&header_set, ":protocol", "websocket"));
    try std.testing.expect(!header_set.process_header(null));

    // Extended CONNECT requires :authority as well as :scheme and :path.
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":protocol", "websocket"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/tunnel"));
    try std.testing.expect(!header_set.process_header(null));

    // A complete extended CONNECT passes the pseudo-header stage.
    header_set.reset(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":protocol", "websocket"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/tunnel"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("/tunnel", header_set.request.target);
}

test "quic: datagram ring rebases non-power-of-two cursors below the u32 ceiling" {
    const capacity = 3;
    const stride = 2;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try datagram_ring.DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );
    // Position an empty ring two slots below the cursor limit.
    ring.head = std.math.maxInt(u32) - 1;
    ring.tail = std.math.maxInt(u32) - 1;

    try ring.push(.{ .session_id = 0, .sequence_number = 0, .payload = "aa" });
    try ring.push(.{ .session_id = 1, .sequence_number = 1, .payload = "bb" });
    try ring.push(.{ .session_id = 2, .sequence_number = 2, .payload = "cc" });
    try std.testing.expect(ring.is_full());
    // The third push rebased both cursors by one capacity instead of wrapping.
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, ring.tail);
    try std.testing.expect(ring.head < ring.tail);

    const first = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence_number);
    try std.testing.expectEqualStrings("aa", first.payload);
    const second = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 1), second.sequence_number);
    try std.testing.expectEqualStrings("bb", second.payload);
    const third = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 2), third.sequence_number);
    try std.testing.expectEqualStrings("cc", third.payload);
    try std.testing.expect(ring.is_empty());

    // The rebased ring keeps serving after the wrap point.
    try ring.push(.{ .session_id = 3, .sequence_number = 3, .payload = "dd" });
    try std.testing.expectEqualStrings("dd", ring.pop().?.payload);
}

test "quic: HTTP/3 trailers reject pseudo and framing fields" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset_trailer(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);

    try std.testing.expect(add_test_header(&header_set, "x-checksum", "complete"));
    try std.testing.expect(header_set.process_header(null));

    header_set.reset_trailer(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(!add_test_header(&header_set, ":path", "/late"));

    header_set.reset_trailer(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(!add_test_header(&header_set, "content-length", "0"));

    header_set.reset_trailer(&owner, Owner.release, &storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(!add_test_header(&header_set, "host", "example.com"));
}

test "quic: HTTP/3 trailer sets are released after one phase transition" {
    const Release = struct {
        var count: usize = 0;

        fn header(_: *anyopaque, _: *HeaderSet) void {
            count += 1;
        }
    };
    var owner: u8 = 0;
    var request_storage: [stream.header_capacity]u8 = undefined;
    var request_headers = HeaderSet{};
    request_headers.reset(
        &owner,
        Release.header,
        &request_storage,
        &.{},
        &.{},
        stream.default_capacities,
    );
    try std.testing.expect(add_test_header(&request_headers, ":method", "POST"));
    try std.testing.expect(add_test_header(&request_headers, ":scheme", "https"));
    try std.testing.expect(add_test_header(&request_headers, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&request_headers, ":path", "/upload"));
    try std.testing.expect(request_headers.process_header(null));

    var quic_stream = stream.QuicStream{ .stream = undefined };
    quic_stream.attach_headers(&request_headers);

    var trailer_storage: [stream.header_capacity]u8 = undefined;
    var trailers = HeaderSet{};
    trailers.reset_trailer(
        &owner,
        Release.header,
        &trailer_storage,
        &.{},
        &.{},
        stream.default_capacities,
    );
    try std.testing.expect(add_test_header(&trailers, "x-checksum", "complete"));
    try std.testing.expect(trailers.process_header(null));

    Release.count = 0;
    quic_stream.attach_headers(&trailers);
    try std.testing.expectEqual(@as(usize, 1), Release.count);
    try std.testing.expect(quic_stream.header_set == &request_headers);
    try std.testing.expect(trailers.release_fn == null);

    request_headers.release();
    try std.testing.expectEqual(@as(usize, 2), Release.count);
}

test "quic: pure header validation rejects malformed metadata" {
    try std.testing.expect(validation.valid_method("PATCH"));
    try std.testing.expect(!validation.valid_method("BAD METHOD"));
    try std.testing.expect(validation.valid_target("/path?value=1"));
    try std.testing.expect(!validation.valid_target("/path#fragment"));
    try std.testing.expect(!validation.valid_target("/bad path"));
    try std.testing.expect(!validation.valid_target("/bad%2"));
    try std.testing.expect(validation.valid_target("*"));
    try std.testing.expect(validation.valid_authority("example.com:443"));
    try std.testing.expect(validation.valid_authority("[::1]:443"));
    try std.testing.expect(!validation.valid_authority("user@example.com"));
    try std.testing.expect(!validation.valid_authority("example.com/path"));
    try std.testing.expect(validation.valid_http3_name("content-type"));
    try std.testing.expect(!validation.valid_http3_name("Content-Type"));
    try std.testing.expect(!validation.valid_header_value("value\r\ninjected"));
    try std.testing.expect(validation.connection_specific_header("Connection"));
    try std.testing.expectEqual(@as(?usize, 4096), validation.parse_decimal("4096"));
    try std.testing.expect(validation.parse_decimal("184467440737095516160") == null);
}

fn add_test_header(header_set: *HeaderSet, name: []const u8, value: []const u8) bool {
    const start = header_set.write_offset;
    if (name.len + value.len > header_set.storage.len - start) return false;
    @memcpy(header_set.storage[start .. start + name.len], name);
    @memcpy(header_set.storage[start + name.len .. start + name.len + value.len], value);

    var header = std.mem.zeroes(c.struct_uz_lsxpack_header);
    header.buf = @ptrCast(header_set.storage.ptr);
    header.name_offset = @intCast(start);
    header.name_len = @intCast(name.len);
    header.val_offset = @intCast(start + name.len);
    header.val_len = @intCast(value.len);
    header_set.decoded = header;
    return header_set.process_header(@ptrCast(&header_set.decoded));
}

/// Records the lsquic stream calls made by the HTTP/3 response state machine.
const FakeStream = struct {
    headers: usize = 0,
    write_bytes: usize = 0,
    wantread: c_int = -1,
    wantwrite: c_int = -1,
    shutdowns: usize = 0,
    closes: usize = 0,
    blocked: bool = false,
};

/// Stand-in lsquic stream entry points receiving a `FakeStream` handle.
const FakeStreamIo = struct {
    fn from(raw: ?*c.lsquic_stream) *FakeStream {
        return @ptrCast(@alignCast(raw.?));
    }

    fn wantread(raw: ?*c.lsquic_stream, want: c_int) callconv(.c) c_int {
        from(raw).wantread = want;
        return 0;
    }

    fn read(raw: ?*c.lsquic_stream, buffer: ?*anyopaque, length: usize) callconv(.c) isize {
        _ = raw;
        _ = buffer;
        _ = length;
        return 0;
    }

    fn wantwrite(raw: ?*c.lsquic_stream, want: c_int) callconv(.c) c_int {
        from(raw).wantwrite = want;
        return 0;
    }

    fn write(raw: ?*c.lsquic_stream, buffer: ?*const anyopaque, length: usize) callconv(.c) isize {
        _ = buffer;
        const state = from(raw);
        if (state.blocked) return 0;
        state.write_bytes += length;
        return @intCast(length);
    }

    fn send_headers(
        raw: ?*c.lsquic_stream,
        headers: [*c]const c.lsquic_http_headers_t,
        eos: c_int,
    ) callconv(.c) c_int {
        _ = headers;
        _ = eos;
        from(raw).headers += 1;
        return 0;
    }

    fn shutdown(raw: ?*c.lsquic_stream, how: c_int) callconv(.c) c_int {
        _ = how;
        from(raw).shutdowns += 1;
        return 0;
    }

    fn close(raw: ?*c.lsquic_stream) callconv(.c) c_int {
        from(raw).closes += 1;
        return 0;
    }

    const table: stream.StreamIo = .{
        .wantread = wantread,
        .read = read,
        .wantwrite = wantwrite,
        .write = write,
        .send_headers = send_headers,
        .shutdown = shutdown,
        .close = close,
    };
};

const TestQuicStream = stream.stream_with(FakeStreamIo.table, stream.default_capacities);

const TestRelease = struct {
    fn release(_: *anyopaque, _: *TestQuicStream) void {}
};

fn test_quic_stream(
    fake: *FakeStream,
    body_storage: []u8,
    header_storage: []u8,
) TestQuicStream {
    return .{
        .owner = undefined,
        .release_fn = TestRelease.release,
        .stream = @ptrCast(fake),
        .router = undefined,
        .body_storage = body_storage,
        .response_body_storage = body_storage,
        .response_header_storage = header_storage,
    };
}

test "quic: HTTP/3 producer completes synchronously and drains on write" {
    const Producer = struct {
        fn produce(_: *anyopaque, response: *Response) anyerror!StreamStatus {
            try response.write_chunk("small body");
            try response.end_chunks();
            return .done;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);
    var marker: u8 = 0;

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try std.testing.expect(quic.target().begin_stream_fn != null);
    try response.begin_stream("200 OK", "", &marker, Producer.produce);

    try std.testing.expect(response.is_complete());
    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.response_phase == .ready);
    try std.testing.expectEqual(@as(usize, "small body".len), quic.response_body_length);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);

    quic.on_write();

    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 1), fake.headers);
    try std.testing.expectEqual(@as(usize, "small body".len), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
    try std.testing.expectEqual(@as(usize, 0), fake.closes);
}

test "quic: HTTP/3 producer resumes across write drain events" {
    const Producer = struct {
        const total: usize = 200;
        remaining: usize = total,
        chunk: [64]u8 = undefined,

        fn produce(context: *anyopaque, response: *Response) anyerror!StreamStatus {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memset(&self.chunk, 'x');
            while (self.remaining != 0) {
                const count = @min(self.remaining, self.chunk.len);
                response.write_chunk(self.chunk[0..count]) catch |err| switch (err) {
                    error.WouldBlock => return .pending,
                    else => return err,
                };
                self.remaining -= count;
            }
            try response.end_chunks();
            return .done;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);

    var producer = Producer{};
    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &producer, Producer.produce);

    try std.testing.expect(!response.is_complete());
    try std.testing.expect(quic.stream_producer != null);
    try std.testing.expectEqual(@as(usize, 64), quic.response_body_length);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);

    var iterations: usize = 0;
    while (quic.stream_producer != null and iterations < 16) : (iterations += 1) {
        quic.on_write();
    }

    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 0), producer.remaining);
    try std.testing.expectEqual(@as(usize, Producer.total), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.headers);
}

test "quic: HTTP/3 producer fault before the head queues a 500" {
    const Producer = struct {
        fn produce(_: *anyopaque, response: *Response) anyerror!StreamStatus {
            try response.write_chunk("partial");
            return error.ProducerFailed;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);
    var marker: u8 = 0;

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &marker, Producer.produce);

    try std.testing.expect(response.is_complete());
    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.stream_producer_context == null);
    try std.testing.expect(quic.response_phase == .ready);
    try std.testing.expectEqual(@as(usize, 0), quic.response_body_length);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);

    quic.on_write();

    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 1), fake.headers);
    try std.testing.expectEqual(@as(usize, 0), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 0), fake.closes);
}

test "quic: HTTP/3 producer fault after the head closes the stream" {
    const Producer = struct {
        wrote: bool = false,

        fn produce(context: *anyopaque, response: *Response) anyerror!StreamStatus {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.wrote) return error.ProducerFailed;
            try response.write_chunk("partial");
            self.wrote = true;
            return .pending;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);

    var producer = Producer{};
    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &producer, Producer.produce);
    try std.testing.expect(quic.stream_producer != null);

    quic.on_write();

    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    try std.testing.expectEqual(@as(usize, 0), fake.shutdowns);
}

test "quic: HTTP/3 pending producer steps once per write event" {
    const Producer = struct {
        steps: usize = 0,

        fn produce(context: *anyopaque, _: *Response) anyerror!StreamStatus {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.steps += 1;
            if (self.steps > 8) return error.ProducerStalled;
            return .pending;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);

    var producer = Producer{};
    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &producer, Producer.produce);
    try std.testing.expectEqual(@as(usize, 1), producer.steps);

    quic.on_write();
    quic.on_write();
    quic.on_write();

    try std.testing.expectEqual(@as(usize, 4), producer.steps);
    try std.testing.expect(quic.stream_producer != null);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.headers);
    try std.testing.expectEqual(@as(usize, 0), fake.shutdowns);
}

test "quic: HTTP/3 producer arming rejects started and bodyless responses" {
    const Producer = struct {
        fn produce(_: *anyopaque, _: *Response) anyerror!StreamStatus {
            return .pending;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);
    var marker: u8 = 0;

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &marker, Producer.produce);
    try std.testing.expectError(
        error.ResponseAlreadyStarted,
        response.begin_stream("200 OK", "", &marker, Producer.produce),
    );

    var head_fake = FakeStream{};
    var head_body: [64]u8 = undefined;
    var head_headers: [stream.response_header_capacity]u8 = undefined;
    var head_stream = test_quic_stream(&head_fake, &head_body, &head_headers);
    head_stream.suppress_body = true;
    var head_response = Response{ .target = .{ .http3 = head_stream.target() } };
    try std.testing.expectError(
        error.BodyNotAllowed,
        head_response.begin_stream("200 OK", "", &marker, Producer.produce),
    );
    try std.testing.expect(head_stream.stream_producer == null);

    var empty_fake = FakeStream{};
    var empty_body: [64]u8 = undefined;
    var empty_headers: [stream.response_header_capacity]u8 = undefined;
    var empty_stream = test_quic_stream(&empty_fake, &empty_body, &empty_headers);
    var empty_response = Response{ .target = .{ .http3 = empty_stream.target() } };
    try std.testing.expectError(
        error.BodyNotAllowed,
        empty_response.begin_stream("204 No Content", "", &marker, Producer.produce),
    );
    try std.testing.expect(empty_stream.stream_producer == null);
}

test "quic: HTTP/3 application end_chunks disarms a pending producer" {
    const Producer = struct {
        fn produce(_: *anyopaque, response: *Response) anyerror!StreamStatus {
            try response.write_chunk("partial");
            return .pending;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);
    var marker: u8 = 0;

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &marker, Producer.produce);
    try std.testing.expect(quic.stream_producer != null);

    try response.end_chunks();

    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.response_phase == .ready);

    quic.on_write();

    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, "partial".len), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
}

test "quic: HTTP/3 stream close clears the armed producer" {
    const Producer = struct {
        fn produce(_: *anyopaque, _: *Response) anyerror!StreamStatus {
            return .pending;
        }
    };

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);
    var marker: u8 = 0;

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_stream("200 OK", "", &marker, Producer.produce);
    try std.testing.expect(quic.stream_producer != null);

    quic.on_close();

    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expect(quic.stream_producer_context == null);
}

test "quic: HTTP/3 non-producer streaming keeps the phase machine" {
    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.begin_chunked("200 OK", "X-Mode: buffered\r\n");

    try std.testing.expect(quic.response_phase == .streaming);
    try std.testing.expect(quic.stream_producer == null);
    try std.testing.expectEqual(@as(c_int, -1), fake.wantwrite);

    try response.write_chunk("hello");
    try std.testing.expectEqual(@as(usize, 5), quic.response_body_length);
    var overflow = [_]u8{'x'} ** 60;
    try std.testing.expectError(error.WouldBlock, response.write_chunk(&overflow));

    try response.end_chunks();
    try std.testing.expect(quic.response_phase == .ready);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);

    quic.on_write();

    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 5), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);

    var guard_fake = FakeStream{};
    var guard_body: [64]u8 = undefined;
    var guard_headers: [stream.response_header_capacity]u8 = undefined;
    var guard_stream = test_quic_stream(&guard_fake, &guard_body, &guard_headers);
    const guard_target = guard_stream.target();
    try guard_target.begin_fn(guard_target.context, "200 OK", "");
    try std.testing.expect(guard_stream.response_phase == .streaming);
    try guard_target.finish_fn(guard_target.context);
    try std.testing.expect(guard_stream.response_phase == .ready);
    try std.testing.expectError(
        error.ResponseNotStreaming,
        guard_target.write_fn(guard_target.context, "late"),
    );
}

/// Records the route captures observed by a wide HTTP/3 handler.
const WideCaptureSink = struct {
    inline_count: usize = 0,
    extra_count: usize = 0,
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,

    fn handle(context: *anyopaque, request: *Request, response: *Response) void {
        const self: *WideCaptureSink = @ptrCast(@alignCast(context));
        self.inline_count = request.route_param_count;
        self.extra_count = request.extra_param_count;
        self.first = request.get_param("p0");
        self.last = request.get_param("p19");
        response.end("200 OK", "") catch {};
    }
};

test "quic: captures beyond 16 resolve from engine storage" {
    const radix = support.radix;
    const capacities = radix.Capacities{ .max_route_params = 20 };
    var bundle = radix.Bundle(capacities){};
    var router = try radix.Router.init(bundle.storage());
    const pattern = "/:p0/:p1/:p2/:p3/:p4/:p5/:p6/:p7/:p8/:p9/:p10/:p11/:p12/:p13/:p14/:p15/:p16/:p17/:p18/:p19";
    const path = "/a0/a1/a2/a3/a4/a5/a6/a7/a8/a9/a10/a11/a12/a13/a14/a15/a16/a17/a18/a19";
    var sink = WideCaptureSink{};
    try router.route_context(.get, pattern, &sink, WideCaptureSink.handle);

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var response_header_storage: [stream.response_header_capacity]u8 = undefined;
    var extra_names: [4][]const u8 = undefined;
    var extra_values: [4][]const u8 = undefined;
    var owner: u8 = 0;
    var quic = TestQuicStream{};
    quic.reset(
        &owner,
        TestRelease.release,
        @ptrCast(&fake),
        &router,
        &body_storage,
        &body_storage,
        &response_header_storage,
        &extra_names,
        &extra_values,
        &.{},
        &.{},
    );

    const HeaderOwner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var header_storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    header_set.reset(
        &owner,
        HeaderOwner.release,
        &header_storage,
        &.{},
        &.{},
        stream.default_capacities,
    );
    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", path));
    try std.testing.expect(header_set.process_header(null));
    quic.attach_headers(&header_set);
    quic.on_read();

    try std.testing.expectEqual(@as(usize, 16), sink.inline_count);
    try std.testing.expectEqual(@as(usize, 4), sink.extra_count);
    try std.testing.expectEqualStrings("a0", sink.first.?);
    try std.testing.expectEqualStrings("a19", sink.last.?);
}

test "quic: HTTP/3 write backpressure keeps the stream armed" {
    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &header_storage);

    var response = Response{ .target = .{ .http3 = quic.target() } };
    fake.blocked = true;
    try response.begin_chunked("200 OK", "");
    try response.write_chunk("body");
    try response.end_chunks();

    quic.on_write();

    try std.testing.expect(quic.response_phase == .sending);
    try std.testing.expectEqual(@as(c_int, 1), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.headers);

    fake.blocked = false;
    quic.on_write();

    try std.testing.expect(quic.response_phase == .done);
    try std.testing.expectEqual(@as(usize, 4), fake.write_bytes);
    try std.testing.expectEqual(@as(c_int, 0), fake.wantwrite);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
}

test "quic: completed exchange emits one development-log request record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "http3_dev_log.txt", .{});
    const sink = support.dev_log.thread_sink();
    const previous_sink = sink.*;
    sink.* = .{};
    sink.enable(std.testing.io, file);
    defer sink.* = previous_sink;
    defer file.close(std.testing.io);

    var fake = FakeStream{};
    var body_storage: [64]u8 = undefined;
    var response_header_storage: [stream.response_header_capacity]u8 = undefined;
    var quic = test_quic_stream(&fake, &body_storage, &response_header_storage);

    const RequestOwner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    var request_storage: [stream.header_capacity]u8 = undefined;
    var request_headers = HeaderSet{};
    request_headers.reset(
        &owner,
        RequestOwner.release,
        &request_storage,
        &.{},
        &.{},
        stream.default_capacities,
    );
    try std.testing.expect(add_test_header(&request_headers, ":method", "GET"));
    try std.testing.expect(add_test_header(&request_headers, ":scheme", "https"));
    try std.testing.expect(add_test_header(&request_headers, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&request_headers, ":path", "/observed"));
    try std.testing.expect(request_headers.process_header(null));
    quic.attach_headers(&request_headers);

    var response = Response{ .target = .{ .http3 = quic.target() } };
    try response.end("204 No Content", "");
    quic.on_write();
    quic.on_write();

    const written = try tmp.dir.readFileAlloc(
        std.testing.io,
        "http3_dev_log.txt",
        std.testing.allocator,
        .limited(support.dev_log.capacity),
    );
    defer std.testing.allocator.free(written);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "[GET]"));
    try std.testing.expect(std.mem.find(u8, written, " /observed : ") != null);
    try std.testing.expect(std.mem.find(u8, written, "204") != null);
}

test "quic: configured response header capacity accepts wide headers" {
    const WideStream = stream.stream_with(FakeStreamIo.table, stream.Capacities{
        .response_header_size = 8 * 1024,
        .response_header_count = 96,
    });
    const WideRelease = struct {
        fn release(_: *anyopaque, _: *WideStream) void {}
    };

    var head_storage: [8 * 1024]u8 = undefined;
    var value_storage: [48]u8 = undefined;
    @memset(&value_storage, 'v');
    var head_length: usize = 0;
    for (0..80) |index| {
        const line = try std.fmt.bufPrint(
            head_storage[head_length..],
            "x-fill-{d}: {s}\r\n",
            .{ index, value_storage },
        );
        head_length += line.len;
    }
    try std.testing.expect(head_length > 4 * 1024);

    var wide_fake = FakeStream{};
    var wide_body: [64]u8 = undefined;
    var wide_header_storage: [8 * 1024]u8 = undefined;
    var wide = WideStream{
        .owner = undefined,
        .release_fn = WideRelease.release,
        .stream = @ptrCast(&wide_fake),
        .router = undefined,
        .body_storage = &wide_body,
        .response_body_storage = &wide_body,
        .response_header_storage = &wide_header_storage,
    };
    const wide_target = wide.target();
    try wide_target.begin_fn(wide_target.context, "200 OK", head_storage[0..head_length]);

    try std.testing.expectEqual(@as(usize, 80), wide.response_header_count);
    try std.testing.expect(wide.response_header_length > 4 * 1024);

    // A non-producer streaming response arms its final drain through `finish`.
    try wide_target.finish_fn(wide_target.context);
    wide.on_write();

    try std.testing.expectEqual(@as(usize, 1), wide_fake.headers);
    try std.testing.expect(wide.response_phase == .done);

    var default_fake = FakeStream{};
    var default_body: [64]u8 = undefined;
    var default_header_storage: [stream.response_header_capacity]u8 = undefined;
    var default_stream = test_quic_stream(&default_fake, &default_body, &default_header_storage);
    const default_target = default_stream.target();
    try std.testing.expectError(
        error.BufferOverflow,
        default_target.begin_fn(default_target.context, "200 OK", head_storage[0..head_length]),
    );
}

test "quic: request headers spill into engine extras" {
    const capacities = stream.Capacities{
        .decoded_header_count = 72,
        .header_extra_capacity = 8,
    };
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    var storage: [stream.header_capacity]u8 = undefined;
    var extra_names: [capacities.header_extra_capacity][]const u8 = undefined;
    var extra_values: [capacities.header_extra_capacity][]const u8 = undefined;
    var header_set = HeaderSet{};
    header_set.reset(
        &owner,
        Owner.release,
        &storage,
        &extra_names,
        &extra_values,
        capacities,
    );

    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/spill"));

    var name_storage: [24]u8 = undefined;
    var value_buffer: [24]u8 = undefined;
    for (0..70) |index| {
        const name = try std.fmt.bufPrint(&name_storage, "x-spill-{d}", .{index});
        const value = try std.fmt.bufPrint(&value_buffer, "value-{d}", .{index});
        try std.testing.expect(add_test_header(&header_set, name, value));
    }
    try std.testing.expect(header_set.process_header(null));

    // The 70 spilled fields plus the authority-derived `host` field fill 7 of
    // the 8 engine-provided slots; the inline and spilled fields are both
    // visible through the request view.
    try std.testing.expectEqual(@as(usize, 70), header_set.decoded_field_count);
    try std.testing.expectEqual(@as(usize, 7), header_set.request.extra_header_count);
    // The request view exposes all 70 inline and spilled fields plus `host`.
    var entries = header_set.request.header_entries();
    var visible: usize = 0;
    while (entries.next()) |_| visible += 1;
    try std.testing.expectEqual(@as(usize, 71), visible);
    try std.testing.expectEqualStrings("value-0", header_set.request.get_header("x-spill-0").?);
    try std.testing.expectEqualStrings("value-63", header_set.request.get_header("x-spill-63").?);
    try std.testing.expectEqualStrings("value-64", header_set.request.get_header("x-spill-64").?);
    try std.testing.expectEqualStrings("value-69", header_set.request.get_header("x-spill-69").?);
    try std.testing.expectEqualStrings("localhost", header_set.request.get_header("host").?);

    var strict_storage: [stream.header_capacity]u8 = undefined;
    var strict = HeaderSet{};
    strict.reset(&owner, Owner.release, &strict_storage, &.{}, &.{}, stream.default_capacities);
    try std.testing.expect(add_test_header(&strict, ":method", "GET"));
    try std.testing.expect(add_test_header(&strict, ":scheme", "https"));
    try std.testing.expect(add_test_header(&strict, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&strict, ":path", "/strict"));

    var accepted: usize = 0;
    for (0..64) |index| {
        const name = try std.fmt.bufPrint(&name_storage, "x-strict-{d}", .{index});
        if (!add_test_header(&strict, name, "v")) break;
        accepted += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), accepted);
    try std.testing.expect(!add_test_header(&strict, "x-overflow", "v"));
}
