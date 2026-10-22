const std = @import("std");
const support = @import("test_support");
const deflate = support.ws_deflate;
const handshake = support.ws_handshake;
const PubSubEngine = support.ws_pubsub.PubSubEngine;
const ws_socket = support.ws_socket;
const WebSocket = ws_socket.WebSocket;
const TcpConnection = support.tcp.TcpConnection;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const mask = support.ws_mask;
const utf8 = support.ws_utf8;
const zslay = @import("zslay");

test "ws: scalar and SIMD masking paths are equivalent" {
    const key: zslay.MaskingKey = .{ 0x12, 0x34, 0x56, 0x78 };
    const input = "unaligned masking payload spanning several vectors";
    var scalar: [input.len]u8 = input.*;
    var simd: [input.len]u8 = input.*;

    mask.apply_scalar(&scalar, key, 7);
    mask.apply_simd(&simd, key, 7);
    try std.testing.expectEqualSlices(u8, &scalar, &simd);

    mask.apply_scalar(&scalar, key, 7);
    try std.testing.expectEqualStrings(input, &scalar);
}

// tests websocket accept token computation based on rfc 6455
test "ws: compute_accept_token" {
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    var out_buffer: [28]u8 = undefined;

    const accept_token = handshake.compute_accept_token(client_key, &out_buffer);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_token);
}

test "ws: validates the complete upgrade handshake" {
    const key = try handshake.validate_request(
        "GET",
        "keep-alive, Upgrade",
        "websocket",
        "13",
        "dGhlIHNhbXBsZSBub25jZQ==",
    );
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key);

    try std.testing.expectError(
        error.InvalidKey,
        handshake.validate_request("GET", "Upgrade", "websocket", "13", "not-base64"),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        handshake.validate_request("GET", "Upgrade", "websocket", "12", "dGhlIHNhbXBsZSBub25jZQ=="),
    );
}

test "ws: upgrade reads handshake fields past the inline header slots" {
    var write_queue: [4096]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var tcp_conn = TcpConnection{
        .socket = undefined,
        .write_queue = &write_queue,
        .ws_message_buffer = &message_buffer,
        // Keep the queued response in the ring instead of arming a socket write.
        .is_writing = true,
    };
    var req = Request{};
    req.method = "GET";
    req.header_names[0] = "Host";
    req.header_values[0] = "example.test";
    req.header_names[1] = "Connection";
    req.header_values[1] = "Upgrade";
    req.header_names[2] = "Upgrade";
    req.header_values[2] = "websocket";
    req.header_names[3] = "Sec-WebSocket-Version";
    req.header_values[3] = "13";
    req.header_count = 4;
    var extra_names = [_][]const u8{"Sec-WebSocket-Key"};
    var extra_values = [_][]const u8{"dGhlIHNhbXBsZSBub25jZQ=="};
    req.extra_header_names = &extra_names;
    req.extra_header_values = &extra_values;
    req.extra_header_count = 1;

    var res = Response{ .target = .{ .tcp = &tcp_conn } };
    var ws = WebSocket{ .conn = &tcp_conn };
    ws.upgrade(&req, &res, .{ .max_frame_size = 64, .max_message_size = 64 });

    try std.testing.expect(ws.initialized);
    try std.testing.expect(
        std.mem.indexOf(u8, &write_queue, "101 Switching Protocols") != null,
    );

    // A duplicate key in the extra slots must fail the unique-field rule.
    var duplicate_names = [_][]const u8{
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Key",
    };
    var duplicate_values = [_][]const u8{
        "dGhlIHNhbXBsZSBub25jZQ==",
        "dGhlIHNhbXBsZSBub25jZQ==",
    };
    var duplicate_req = req;
    duplicate_req.extra_header_names = &duplicate_names;
    duplicate_req.extra_header_values = &duplicate_values;
    duplicate_req.extra_header_count = 2;

    var duplicate_queue: [4096]u8 = undefined;
    var duplicate_message_buffer: [64]u8 = undefined;
    var duplicate_conn = TcpConnection{
        .socket = undefined,
        .write_queue = &duplicate_queue,
        .ws_message_buffer = &duplicate_message_buffer,
        .is_writing = true,
    };
    var duplicate_res = Response{ .target = .{ .tcp = &duplicate_conn } };
    var duplicate_ws = WebSocket{ .conn = &duplicate_conn };
    duplicate_ws.upgrade(
        &duplicate_req,
        &duplicate_res,
        .{ .max_frame_size = 64, .max_message_size = 64 },
    );

    try std.testing.expect(!duplicate_ws.initialized);
    try std.testing.expect(
        std.mem.indexOf(u8, &duplicate_queue, "400 Bad Request") != null,
    );
}

test "ws: zslay server rejects unmasked client frames" {
    var nodes: [2]zslay.FrameNode = undefined;
    var conn = try zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = 1024,
        .max_message_len = 1024,
    });
    var header: zslay.FrameHeaderBuffer = undefined;
    const header_len = try zslay.encode_header(&header, .{
        .payload_len = 0,
        .mask = false,
        .opcode = @intFromEnum(zslay.Opcode.text),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
    }, 0, null);

    @memcpy(conn.get_header_buffer(), header[0..header_len]);
    try conn.advance_header_read(header_len);
    try std.testing.expectError(error.PayloadNotMasked, conn.advance_rx());
}

test "ws: zslay enforces frame limits from extended headers" {
    var nodes: [2]zslay.FrameNode = undefined;
    var conn = try zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = 1024,
        .max_message_len = 1024,
    });
    var header: zslay.FrameHeaderBuffer = undefined;
    const masking_key = [_]u8{ 1, 2, 3, 4 };
    const header_len = try zslay.encode_header(&header, .{
        .payload_len = 126,
        .mask = true,
        .opcode = @intFromEnum(zslay.Opcode.binary),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
    }, 2048, masking_key);

    var offset: usize = 0;
    while (offset < header_len) {
        try std.testing.expectEqual(zslay.RxAction.need_header, try conn.advance_rx());
        const destination = conn.get_header_buffer();
        const copy_len = @min(destination.len, header_len - offset);
        @memcpy(destination[0..copy_len], header[offset .. offset + copy_len]);
        try conn.advance_header_read(copy_len);
        offset += copy_len;
    }
    try std.testing.expectError(error.PayloadTooLarge, conn.advance_rx());
}

test "ws: SIMD mask is position-aware and reversible" {
    const key = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    var payload = "0123456789abcdefghijklmnopqrstuvwxyz".*;
    const original = payload;

    mask.apply(&payload, key, 0);
    try std.testing.expect(!std.mem.eql(u8, &payload, &original));
    mask.apply(&payload, key, 0);
    try std.testing.expectEqualSlices(u8, &original, &payload);
}

test "ws: SIMD mask preserves key position across chunks" {
    const key = [_]u8{ 1, 2, 3, 4 };
    var whole = "0123456789abcdefghijklmnop".*;
    var split = whole;

    mask.apply(&whole, key, 0);
    mask.apply(split[0..7], key, 0);
    mask.apply(split[7..], key, 7);
    try std.testing.expectEqualSlices(u8, &whole, &split);
}

test "ws: SIMD mask matches scalar across tails and key rotations" {
    const key = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var simd: [96]u8 = undefined;
    var scalar: [96]u8 = undefined;

    for (1..simd.len + 1) |len| {
        for (0..key.len) |position| {
            for (0..len) |index| simd[index] = @intCast(index % 251);
            scalar = simd;
            mask.apply_simd(simd[0..len], key, position);
            mask.apply_scalar(scalar[0..len], key, position);
            try std.testing.expectEqualSlices(u8, scalar[0..len], simd[0..len]);
        }
    }
}

test "ws: masking position wraps across fragmented chunks" {
    const key = [_]u8{ 1, 2, 3, 4 };
    const position = std.math.maxInt(u64) - 2;
    var whole = "0123456789abcdefghijklmnop".*;
    var split = whole;
    const split_at = 7;

    mask.apply(&whole, key, position);
    mask.apply(split[0..split_at], key, position);
    mask.apply(
        split[split_at..],
        key,
        position +% @as(u64, @intCast(split_at)),
    );
    try std.testing.expectEqualSlices(u8, &whole, &split);
}

test "ws: streaming UTF-8 validation fails at the offending byte" {
    var state = utf8.validate_chunk(.{}, &.{ 0xf0, 0x90 }) orelse unreachable;
    try std.testing.expect(!utf8.is_complete(state));
    state = utf8.validate_chunk(state, &.{ 0x80, 0x80 }) orelse unreachable;
    try std.testing.expect(utf8.is_complete(state));

    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xf4, 0x90 }) == null);
    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xed, 0xa0, 0x80 }) == null);
    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xc0, 0x80 }) == null);
}

test "ws: pubsub owns topics and reclaims subscriptions" {
    var engine = PubSubEngine{};
    var first_socket: WebSocket = undefined;
    var second_socket: WebSocket = undefined;
    var topic = "room".*;

    try engine.subscribe(&first_socket, &topic);
    try engine.subscribe(&first_socket, &topic);
    try engine.subscribe(&second_socket, &topic);
    try std.testing.expectEqual(@as(usize, 2), engine.sub_count);

    topic[0] = 'x';
    try std.testing.expect(engine.unsubscribe(&first_socket, "room"));
    engine.unsubscribe_all(&second_socket);
    try std.testing.expectEqual(@as(usize, 0), engine.sub_count);
    try std.testing.expectEqual(@as(usize, 0), engine.topic_count);
}

test "ws: full subscription storage does not leak empty topics" {
    var engine = PubSubEngine{};
    var socket: WebSocket = undefined;
    engine.sub_count = support.ws_pubsub.max_subscriptions;

    try std.testing.expectError(
        error.SubscriptionCapacityReached,
        engine.subscribe(&socket, "unused"),
    );
    try std.testing.expectEqual(@as(usize, 0), engine.topic_count);
}

/// Initializes a send-capable socket whose encoded frames stay in `write_queue`.
fn init_pubsub_socket(socket: *WebSocket, conn: *TcpConnection, write_queue: []u8) !void {
    conn.* = .{
        .socket = undefined,
        .write_queue = write_queue,
        // Keep frames in the ring instead of arming a socket write.
        .is_writing = true,
    };
    // zslay keeps a pointer to the socket's tx_nodes, so initialize in place.
    socket.* = .{
        .conn = conn,
        .behavior = .{ .max_frame_size = 64, .max_message_size = 64 },
        .initialized = true,
    };
    socket.z_conn = try zslay.Conn.init(&socket.tx_nodes, .{
        .role = .server,
        .max_frame_len = 64,
        .max_message_len = 64,
    });
}

test "ws: pubsub defers reentrant removals until the publish frame ends" {
    var engine = PubSubEngine{};
    var first_conn: TcpConnection = undefined;
    var first_socket: WebSocket = undefined;
    var first_write: [64]u8 = undefined;
    try init_pubsub_socket(&first_socket, &first_conn, &first_write);
    var second_conn: TcpConnection = undefined;
    var second_socket: WebSocket = undefined;
    var second_write: [64]u8 = undefined;
    try init_pubsub_socket(&second_socket, &second_conn, &second_write);
    var third_conn: TcpConnection = undefined;
    var third_socket: WebSocket = undefined;
    var third_write: [64]u8 = undefined;
    try init_pubsub_socket(&third_socket, &third_conn, &third_write);

    try engine.subscribe(&first_socket, "alpha");
    try engine.subscribe(&second_socket, "beta");
    try engine.subscribe(&first_socket, "gamma");
    try std.testing.expectEqual(@as(usize, 3), engine.sub_count);

    // Simulate a publish frame that is still active when a failed send tears
    // down the transport's subscriptions. The production path sets the same
    // depth in `publish` and compacts through the same `end_publish` defer.
    engine.publish_depth = 1;
    try std.testing.expect(engine.unsubscribe(&first_socket, "alpha"));
    engine.unsubscribe_all(&first_socket);

    try std.testing.expectEqual(@as(usize, 3), engine.sub_count);
    try std.testing.expectEqual(@as(usize, 2), engine.retired_subscriptions);
    try std.testing.expect(engine.empty_topic_pending);
    try std.testing.expect(engine.sub_sockets[0] == null);
    try std.testing.expect(engine.sub_sockets[2] == null);
    // Empty topics stay addressable so live rows keep their topic ids.
    try std.testing.expectEqual(@as(usize, 3), engine.topic_count);
    try std.testing.expectEqual(@as(u16, 0), engine.topic_subscriber_counts[0]);
    try std.testing.expectEqual(@as(u16, 1), engine.topic_subscriber_counts[1]);
    try std.testing.expectEqual(@as(u16, 0), engine.topic_subscriber_counts[2]);
    try std.testing.expectEqual(@as(u16, 1), engine.sub_topic_ids[1]);

    // A subscription made during the frame appends at the high-water mark
    // instead of reviving a tombstone.
    try engine.subscribe(&third_socket, "alpha");
    try std.testing.expectEqual(@as(usize, 4), engine.sub_count);
    try std.testing.expect(engine.sub_sockets[0] == null);
    try std.testing.expect(engine.sub_sockets[3] == &third_socket);
    try std.testing.expectEqual(@as(u16, 0), engine.sub_topic_ids[3]);
    try std.testing.expectEqual(@as(u16, 1), engine.topic_subscriber_counts[0]);

    // The outer frame ends; the next publish skips the tombstones, then
    // compacts and sweeps the gamma topic that became empty.
    engine.publish_depth = 0;
    try std.testing.expectEqual(@as(usize, 1), engine.publish("beta", "b", true));
    try std.testing.expectEqual(@as(usize, 2), engine.sub_count);
    try std.testing.expectEqual(@as(usize, 0), engine.retired_subscriptions);
    try std.testing.expect(!engine.empty_topic_pending);
    try std.testing.expectEqual(@as(usize, 2), engine.topic_count);
    try std.testing.expect(engine.sub_sockets[0] == &second_socket);
    try std.testing.expectEqual(@as(u16, 1), engine.sub_topic_ids[0]);
    try std.testing.expect(engine.sub_sockets[1] == &third_socket);
    try std.testing.expectEqual(@as(u16, 0), engine.sub_topic_ids[1]);
    try std.testing.expect(engine.sub_sockets[2] == null);
    try std.testing.expect(engine.sub_sockets[3] == null);

    // Retired sockets saw nothing. The mid-frame alpha subscription receives
    // only the later alpha publish, and the beta subscriber never receives
    // alpha through a remapped topic id.
    try std.testing.expectEqual(@as(usize, 0), first_conn.write_len);
    try std.testing.expect(second_conn.write_len > 0);
    const beta_bytes = second_conn.write_len;
    try std.testing.expectEqual(@as(usize, 1), engine.publish("alpha", "a", true));
    try std.testing.expectEqual(@as(usize, 0), first_conn.write_len);
    try std.testing.expectEqual(beta_bytes, second_conn.write_len);
    try std.testing.expect(third_conn.write_len > 0);
}

test "ws: fragmented message completes with an empty continuation" {
    const Capture = struct {
        var calls: usize = 0;
        var message_len: usize = 0;
        var opcode: zslay.Opcode = .continuation;

        fn on_message(_: *WebSocket, message: []const u8, message_opcode: zslay.Opcode) void {
            calls += 1;
            message_len = message.len;
            opcode = message_opcode;
        }
    };

    const message_size = 4 * 1024 * 1024;
    const fragment_size = 1024;
    const masking_key = [_]u8{ 1, 2, 3, 4 };
    const message_buffer = try std.testing.allocator.alloc(u8, message_size);
    defer std.testing.allocator.free(message_buffer);

    var tcp_conn = TcpConnection{
        .socket = undefined,
        .ws_message_buffer = message_buffer,
    };
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{
            .message = Capture.on_message,
            .max_frame_size = message_size,
            .max_message_size = message_size,
        },
        .initialized = true,
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = message_size,
        .max_message_len = message_size,
    });

    var wire: [zslay.MaxFrameHeaderLen + fragment_size]u8 = undefined;
    for (0..message_size / fragment_size) |fragment_index| {
        const opcode: zslay.Opcode = if (fragment_index == 0) .text else .continuation;
        const header_len = try zslay.encode_header(
            &wire,
            .{
                .payload_len = 126,
                .mask = true,
                .opcode = @intFromEnum(opcode),
                .rsv3 = false,
                .rsv2 = false,
                .rsv1 = false,
                .fin = false,
            },
            fragment_size,
            masking_key,
        );
        @memset(wire[header_len .. header_len + fragment_size], '*');
        mask.apply(wire[header_len .. header_len + fragment_size], masking_key, 0);
        ws.on_data(wire[0 .. header_len + fragment_size]);
    }

    const final_header_len = try zslay.encode_header(
        &wire,
        .{
            .payload_len = 0,
            .mask = true,
            .opcode = @intFromEnum(zslay.Opcode.continuation),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        },
        0,
        masking_key,
    );
    ws.on_data(wire[0..final_header_len]);

    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    try std.testing.expectEqual(message_size, Capture.message_len);
    try std.testing.expectEqual(zslay.Opcode.text, Capture.opcode);
}

test "ws: invalid UTF-8 is terminal and suppresses later dispatch" {
    const Capture = struct {
        var calls: usize = 0;

        fn on_message(_: *WebSocket, _: []const u8, _: zslay.Opcode) void {
            calls += 1;
        }
    };

    var message_buffer: [64]u8 = undefined;
    var write_queue: [128]u8 = undefined;
    var tcp_conn = TcpConnection{
        .socket = undefined,
        .ws_message_buffer = &message_buffer,
        .write_queue = &write_queue,
        // Keep the close frame in the ring instead of arming a socket write.
        .is_writing = true,
    };
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{
            .message = Capture.on_message,
            .max_frame_size = 64,
            .max_message_size = 64,
        },
        .initialized = true,
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = 64,
        .max_message_len = 64,
    });

    const masking_key = [_]u8{ 1, 2, 3, 4 };
    var wire: [16]u8 = undefined;

    // A complete masked text frame whose payload is invalid UTF-8.
    const invalid_len = try zslay.encode_header(
        &wire,
        .{
            .payload_len = 1,
            .mask = true,
            .opcode = @intFromEnum(zslay.Opcode.text),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        },
        1,
        masking_key,
    );
    wire[invalid_len] = 0xff ^ masking_key[0];

    Capture.calls = 0;
    ws.on_data(wire[0 .. invalid_len + 1]);
    try std.testing.expect(ws.failed);
    try std.testing.expect(ws.close_sent);
    try std.testing.expectEqual(@as(usize, 0), Capture.calls);

    // A valid frame after the failure must never reach the application.
    const valid_len = try zslay.encode_header(
        &wire,
        .{
            .payload_len = 1,
            .mask = true,
            .opcode = @intFromEnum(zslay.Opcode.text),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        },
        1,
        masking_key,
    );
    wire[valid_len] = 'a' ^ masking_key[0];
    ws.on_data(wire[0 .. valid_len + 1]);
    try std.testing.expectEqual(@as(usize, 0), Capture.calls);
}

test "handshake: negotiates bounded no-context permessage-deflate" {
    const negotiated = handshake.negotiate_permessage_deflate(
        "foo, permessage-deflate; client_max_window_bits=12; server_max_window_bits=15",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(?u4, 15), negotiated.server_max_window_bits);
    try std.testing.expectEqual(@as(?u4, 12), negotiated.client_max_window_bits);

    var output: [192]u8 = undefined;
    const response = try handshake.format_permessage_deflate_response(negotiated, &output);
    try std.testing.expectEqualStrings(
        "Sec-WebSocket-Extensions: permessage-deflate" ++
            "; server_no_context_takeover" ++
            "; client_no_context_takeover" ++
            "; server_max_window_bits=15" ++
            "; client_max_window_bits=12\r\n",
        response,
    );
}

test "handshake: ignores malformed permessage-deflate offers" {
    try std.testing.expectEqual(
        null,
        handshake.negotiate_permessage_deflate("permessage-deflate; client_max_window_bits=7"),
    );
    try std.testing.expectEqual(
        null,
        handshake.negotiate_permessage_deflate(
            "permessage-deflate; client_no_context_takeover; client_no_context_takeover",
        ),
    );
    try std.testing.expectEqual(
        null,
        handshake.negotiate_permessage_deflate("permessage-deflate; unknown=value"),
    );
}

test "handshake: declines an 8-bit server compression window" {
    try std.testing.expectEqual(
        null,
        handshake.negotiate_permessage_deflate(
            "permessage-deflate; server_max_window_bits=8",
        ),
    );

    const fallback = handshake.negotiate_permessage_deflate(
        "permessage-deflate; server_max_window_bits=8, permessage-deflate",
    );
    try std.testing.expect(fallback != null);
}

test "deflate: accepts client window 8 and bounds decoded output" {
    const negotiated = handshake.negotiate_permessage_deflate(
        "permessage-deflate; client_max_window_bits=8",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u4, 8), negotiated.client_max_window_bits);

    const expected = "client-window-eight-" ** 8;
    const compressed = [_]u8{
        0x4a, 0xce, 0xc9, 0x4c, 0xcd, 0x2b, 0xd1, 0x2d, 0xcf,
        0xcc, 0x4b, 0xc9, 0x2f, 0xd7, 0x4d, 0xcd, 0x4c, 0xcf,
        0x28, 0xd1, 0x4d, 0x1e, 0x44, 0x62, 0x00, 0x00,
    };

    var context = try deflate.Context.init(6);
    defer context.deinit();
    var scratch: [compressed.len + deflate.decode_tail_len]u8 = undefined;
    @memcpy(scratch[0..compressed.len], &compressed);
    var output: [expected.len]u8 = undefined;
    const restored = try context.decompress_message(
        scratch[0..compressed.len],
        &scratch,
        &output,
    );
    try std.testing.expectEqualStrings(expected, restored);

    @memcpy(scratch[0..compressed.len], &compressed);
    var bounded_output: [expected.len - 1]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        context.decompress_message(
            scratch[0..compressed.len],
            &scratch,
            &bounded_output,
        ),
    );
}

test "deflate: per-message round trip uses caller-owned storage" {
    var context = try deflate.Context.init(6);
    defer context.deinit();

    const input = "bounded per-message deflate payload" ** 8;
    const bound = try context.scratch_bound(input.len);
    const scratch = try std.testing.allocator.alloc(u8, bound);
    defer std.testing.allocator.free(scratch);
    const output = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(output);

    const compressed = try context.compress_message(input, scratch);
    const restored = try context.decompress_message(compressed, scratch, output);
    try std.testing.expectEqualStrings(input, restored);
}

test "deflate: negotiated small windows use preallocated zlib streams" {
    var context = try deflate.Context.init(6);
    defer context.deinit();

    const input = "small-window payload" ** 32;
    const bound = try context.scratch_bound(input.len);
    const scratch = try std.testing.allocator.alloc(u8, bound);
    defer std.testing.allocator.free(scratch);
    const output = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(output);

    var window_bits: u4 = 9;
    while (window_bits <= 14) : (window_bits += 1) {
        const compressed = try context.compress_message_window(input, scratch, window_bits);
        const restored = try context.decompress_message(compressed, scratch, output);
        try std.testing.expectEqualStrings(input, restored);
    }
}

test "deflate: expansion is bounded by output capacity" {
    var context = try deflate.Context.init(6);
    defer context.deinit();

    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const bound = try context.scratch_bound(input.len);
    const scratch = try std.testing.allocator.alloc(u8, bound);
    defer std.testing.allocator.free(scratch);

    const compressed = try context.compress_message(input, scratch);
    var output: [4]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        context.decompress_message(compressed, scratch, &output),
    );
}

test "deflate: malformed input is rejected" {
    var context = try deflate.Context.init(6);
    defer context.deinit();

    var scratch: [64]u8 = undefined;
    @memcpy(scratch[0..4], &[_]u8{ 0xff, 0xff, 0xff, 0xff });
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCompressedData,
        context.decompress_message(scratch[0..4], &scratch, &output),
    );
}

test "websocket validates outgoing application frames" {
    try ws_socket.validate_outgoing_payload("valid", .text);
    try ws_socket.validate_outgoing_payload("", .close);
    try std.testing.expectError(
        error.InvalidUtf8,
        ws_socket.validate_outgoing_payload(&.{ 0xc0, 0x80 }, .text),
    );
    try std.testing.expectError(
        error.InvalidOpcode,
        ws_socket.validate_outgoing_payload("", .continuation),
    );
    try std.testing.expectError(
        error.InvalidCloseFrame,
        ws_socket.validate_outgoing_payload(&.{0x03}, .close),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        ws_socket.validate_outgoing_payload(&.{ 0x03, 0xe8, 0xc0, 0x80 }, .close),
    );
    // 1005 is reserved and must never appear on the wire.
    try std.testing.expectError(
        error.InvalidCloseFrame,
        ws_socket.validate_outgoing_payload(&.{ 0x03, 0xed }, .close),
    );
    // 1012 service_restart is IANA-registered and accepted.
    try ws_socket.validate_outgoing_payload(&.{ 0x03, 0xf4 }, .close);
    // Close control frames stay bounded even though zslay has no length limit.
    // Use valid code 1012 and ASCII reason so only the bound can reject it.
    try std.testing.expectError(
        error.InvalidCloseFrame,
        ws_socket.validate_outgoing_payload(&([_]u8{ 0x03, 0xf4 } ++ ([_]u8{'a'} ** 124)), .close),
    );
    try std.testing.expectError(
        error.ControlFrameTooLarge,
        ws_socket.validate_outgoing_payload(&([_]u8{0} ** 126), .ping),
    );
}

test "handshake: validates RFC 8441 extended connect version" {
    try handshake.validate_extended_connect("13");
    try handshake.validate_extended_connect(" 13 ");
    try std.testing.expectError(
        error.MissingVersion,
        handshake.validate_extended_connect(null),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        handshake.validate_extended_connect("8"),
    );
}

test "ws: terminate is a no-op once the socket is deinitialized" {
    var tcp_conn = TcpConnection{ .socket = undefined };
    var ws = WebSocket{ .conn = &tcp_conn, .initialized = true };

    ws.deinit();
    try std.testing.expect(!ws.initialized);

    // The transport already closed during deinit; a second terminate must not
    // fall through to the HTTP/1 TCP close path.
    ws.terminate();
    try std.testing.expect(!tcp_conn.closing);
}

test "ws: peer close completes the HTTP/1 close handshake after flush" {
    var write_queue: [128]u8 = undefined;
    var tcp_conn = TcpConnection{
        .socket = undefined,
        .write_queue = &write_queue,
        .is_writing = true,
    };
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{ .max_frame_size = 64, .max_message_size = 64 },
        .initialized = true,
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = 64,
        .max_message_len = 64,
    });

    const masking_key = [_]u8{ 1, 2, 3, 4 };
    var wire: [16]u8 = undefined;
    const header_len = try zslay.encode_header(
        &wire,
        .{
            .payload_len = 2,
            .mask = true,
            .opcode = @intFromEnum(zslay.Opcode.close),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        },
        2,
        masking_key,
    );
    wire[header_len] = 0x03 ^ masking_key[0];
    wire[header_len + 1] = 0xe8 ^ masking_key[1];

    ws.on_data(wire[0 .. header_len + 2]);

    try std.testing.expect(ws.close_received);
    try std.testing.expect(ws.close_sent);
    try std.testing.expect(tcp_conn.close_when_drained);
    try std.testing.expect(!tcp_conn.closing);
}

/// Fills `destination` with deterministic high-entropy bytes so DEFLATE has no
/// choice but to expand them.
fn fill_incompressible(destination: []u8) void {
    var counter: u64 = 0;
    var offset: usize = 0;
    while (offset < destination.len) : (counter += 1) {
        var seed: [8]u8 = undefined;
        std.mem.writeInt(u64, &seed, counter, .little);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&seed, &digest, .{});
        const take = @min(digest.len, destination.len - offset);
        @memcpy(destination[offset .. offset + take], digest[0..take]);
        offset += take;
    }
}

/// Connection stub with compression scratch and a write ring as the only sink.
fn compression_connection(
    write_queue: []u8,
    message_buffer: []u8,
    compression_buffer: []u8,
    compression_output: []u8,
    context: *deflate.Context,
) TcpConnection {
    return .{
        .socket = undefined,
        .write_queue = write_queue,
        .ws_message_buffer = message_buffer,
        .ws_compression_buffer = compression_buffer,
        .ws_compression_output_buffer = compression_output,
        .ws_deflate = context,
        .is_writing = true,
    };
}

test "ws: compressed send falls back to the raw payload at the frame limit" {
    var write_queue: [512]u8 = undefined;
    var message_buffer: [256]u8 = undefined;
    var compression_buffer: [256]u8 = undefined;
    var compression_output: [256]u8 = undefined;
    var context = try deflate.Context.init(6);
    defer context.deinit();

    var tcp_conn = compression_connection(
        &write_queue,
        &message_buffer,
        &compression_buffer,
        &compression_output,
        &context,
    );
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{ .max_frame_size = 64, .max_message_size = 256 },
        .initialized = true,
        .permessage_deflate = .{},
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = 64,
        .max_message_len = 256,
    });

    var payload: [64]u8 = undefined;
    fill_incompressible(&payload);
    const compressed = try context.compress_message_window(&payload, &compression_output, 15);
    try std.testing.expect(compressed.len > ws.behavior.max_frame_size);

    try ws.send(&payload, .binary);

    try std.testing.expectEqual(@as(usize, 2 + payload.len), tcp_conn.write_len);
    // FIN + binary without RSV1: the raw payload was sent in place.
    try std.testing.expectEqual(@as(u8, 0x82), write_queue[0]);
    try std.testing.expectEqual(@as(u8, payload.len), write_queue[1]);
    try std.testing.expectEqualSlices(
        u8,
        &payload,
        write_queue[2 .. 2 + payload.len],
    );
}

test "ws: compressed send rejects a payload no frame can carry" {
    var write_queue: [512]u8 = undefined;
    var message_buffer: [256]u8 = undefined;
    var compression_buffer: [256]u8 = undefined;
    var compression_output: [256]u8 = undefined;
    var context = try deflate.Context.init(6);
    defer context.deinit();

    var tcp_conn = compression_connection(
        &write_queue,
        &message_buffer,
        &compression_buffer,
        &compression_output,
        &context,
    );
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{ .max_frame_size = 64, .max_message_size = 256 },
        .initialized = true,
        .permessage_deflate = .{},
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = 64,
        .max_message_len = 256,
    });

    var payload: [65]u8 = undefined;
    fill_incompressible(&payload);

    try std.testing.expectError(error.PayloadTooLarge, ws.send(&payload, .binary));
    try std.testing.expectEqual(@as(usize, 0), tcp_conn.write_len);
}

test "ws: compressed send still marks RSV1 when the compressed form fits" {
    var write_queue: [512]u8 = undefined;
    var message_buffer: [256]u8 = undefined;
    var compression_buffer: [256]u8 = undefined;
    var compression_output: [256]u8 = undefined;
    var context = try deflate.Context.init(6);
    defer context.deinit();

    var tcp_conn = compression_connection(
        &write_queue,
        &message_buffer,
        &compression_buffer,
        &compression_output,
        &context,
    );
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{ .max_frame_size = 256, .max_message_size = 256 },
        .initialized = true,
        .permessage_deflate = .{},
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = 256,
        .max_message_len = 256,
    });

    const payload = "compressible payload " ** 4;
    try ws.send(payload, .binary);

    try std.testing.expect(write_queue[0] & 0x40 != 0);
}
