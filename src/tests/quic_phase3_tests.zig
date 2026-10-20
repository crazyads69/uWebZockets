const std = @import("std");
const support = @import("test_support");
const extensions = support.quic_extensions;
const webtransport = support.webtransport;

test "phase3: websocket extended CONNECT validates RFC 9220 metadata" {
    const valid = extensions.WebSocketConnect{
        .method = "CONNECT",
        .protocol = "websocket",
        .scheme = "https",
        .authority = "example.com",
        .path = "/chat",
        .websocket_version = "13",
        .websocket_version_count = 1,
        .has_connection_header = false,
        .has_upgrade_header = false,
    };
    try extensions.validate_websocket_connect(valid);

    var insecure = valid;
    insecure.scheme = "http";
    try extensions.validate_websocket_connect(insecure);

    var invalid = valid;
    invalid.method = "GET";
    try std.testing.expectError(error.InvalidMethod, extensions.validate_websocket_connect(invalid));
    invalid = valid;
    invalid.protocol = "unknown";
    try std.testing.expectError(error.UnsupportedProtocol, extensions.validate_websocket_connect(invalid));
    try std.testing.expectEqual(
        @as(u16, 501),
        extensions.websocket_error_status(error.UnsupportedProtocol),
    );
    invalid = valid;
    invalid.scheme = "ftp";
    try std.testing.expectError(error.InvalidScheme, extensions.validate_websocket_connect(invalid));
    invalid = valid;
    invalid.has_upgrade_header = true;
    try std.testing.expectError(
        error.ConnectionSpecificHeader,
        extensions.validate_websocket_connect(invalid),
    );
}

test "phase3: invalid settings applications are atomic" {
    var settings = webtransport.Settings{ .initial_max_data = 17 };
    const before_boolean_error = settings;
    try std.testing.expectError(
        error.InvalidBoolean,
        webtransport.apply_setting(&settings, webtransport.settings_h3_datagram, 2),
    );
    try std.testing.expectEqualDeep(before_boolean_error, settings);
    try std.testing.expectEqual(
        webtransport.SettingResult.applied,
        try webtransport.apply_setting(&settings, webtransport.settings_h3_datagram, 1),
    );
    const before_duplicate_error = settings;
    try std.testing.expectError(
        error.DuplicateSetting,
        webtransport.apply_setting(&settings, webtransport.settings_h3_datagram, 0),
    );
    try std.testing.expectEqualDeep(before_duplicate_error, settings);

    const before_limit_error = settings;
    try std.testing.expectError(
        error.InvalidStreamLimit,
        webtransport.apply_setting(
            &settings,
            webtransport.settings_wt_initial_max_streams_uni,
            webtransport.max_stream_count + 1,
        ),
    );
    try std.testing.expectEqualDeep(before_limit_error, settings);

    const before_version_error = settings;
    try std.testing.expectError(
        error.UnsupportedWebTransportVersion,
        webtransport.apply_setting(&settings, webtransport.settings_wt_enabled, 2),
    );
    try std.testing.expectEqualDeep(before_version_error, settings);
}

test "phase3: early data policy defers and rejects replay-unsafe forwarding" {
    try std.testing.expectEqual(
        extensions.EarlyDataDecision.deferred,
        extensions.decide_early_data(.defer_until_confirmed, .{
            .handshake = .in_progress,
            .arrived_before_confirmation = true,
            .forwarded_early_data = false,
            .replay_safe = false,
        }),
    );
    try std.testing.expectEqual(
        extensions.EarlyDataDecision.process,
        extensions.decide_early_data(.defer_until_confirmed, .{
            .handshake = .confirmed,
            .arrived_before_confirmation = true,
            .forwarded_early_data = false,
            .replay_safe = false,
        }),
    );
    try std.testing.expectEqual(
        extensions.EarlyDataDecision.reject_too_early,
        extensions.decide_early_data(.defer_until_confirmed, .{
            .handshake = .confirmed,
            .arrived_before_confirmation = false,
            .forwarded_early_data = true,
            .replay_safe = false,
        }),
    );
    try std.testing.expect(extensions.method_is_replay_safe("GET"));
    try std.testing.expect(extensions.method_is_replay_safe("QUERY"));
    try std.testing.expect(extensions.method_is_replay_safe("TRACE"));
    try std.testing.expect(!extensions.method_is_replay_safe("CONNECT"));
}

test "phase3: pinned lsquic capabilities fail closed" {
    try std.testing.expectEqualDeep(
        extensions.BackendCapabilities{ .quic_datagrams = true },
        extensions.lsquic_4_10_0_capabilities,
    );
}

test "phase3: push bookkeeping refuses the unsupported lsquic backend" {
    const Bookkeeping = extensions.push_bookkeeping(2);
    var pushes = Bookkeeping.init();
    try pushes.apply_max_push_id(1);
    try std.testing.expectError(
        error.BackendUnsupported,
        pushes.reserve(extensions.lsquic_4_10_0_capabilities),
    );

    const capable = extensions.BackendCapabilities{ .server_push = true };
    const first = try pushes.reserve(capable);
    try std.testing.expectEqual(@as(u64, 0), first);
    try pushes.mark_promised(first);
    try pushes.mark_streaming(first);
    try std.testing.expectEqual(extensions.PushState.streaming, pushes.state(first).?);
    try pushes.release(first);
    try std.testing.expectEqual(@as(usize, 0), pushes.count());
    try std.testing.expectError(error.PushIdReduced, pushes.apply_max_push_id(0));
}

test "phase3: current WebTransport constants and settings round trip" {
    try std.testing.expectEqual(@as(u64, 0x2c7cf000), webtransport.settings_wt_enabled);
    try std.testing.expectEqual(@as(u64, 0x2b61), webtransport.settings_wt_initial_max_data);
    try std.testing.expectEqual(@as(u64, 0x2b64), webtransport.settings_wt_initial_max_streams_uni);
    try std.testing.expectEqual(@as(u64, 0x2b65), webtransport.settings_wt_initial_max_streams_bidi);
    try std.testing.expectEqual(@as(u64, 0x1d), webtransport.reset_stream_at_parameter);
    try std.testing.expectEqual(@as(u64, 0x24), webtransport.reset_stream_at_frame);

    const settings = webtransport.Settings{
        .wt_enabled = 1,
        .enable_connect_protocol = 1,
        .h3_datagram = 1,
    };
    var encoded: [64]u8 = undefined;
    const encoded_length = try webtransport.encode_server_settings(settings, &encoded);
    const decoded = try webtransport.decode_settings_payload(encoded[0..encoded_length]);
    try std.testing.expectEqual(@as(u64, 1), decoded.wt_enabled);
    try std.testing.expectEqual(@as(u64, 1), decoded.enable_connect_protocol);
    try std.testing.expectEqual(@as(u64, 1), decoded.h3_datagram);
    try std.testing.expect(webtransport.server_requirements_met(decoded, .{
        .max_datagram_frame_size = 1200,
        .reset_stream_at = true,
    }));
    try std.testing.expectError(
        error.BackendUnsupported,
        webtransport.require_backend(extensions.lsquic_4_10_0_capabilities),
    );
}

test "phase3: QUIC varints accept non-minimal encodings" {
    const values = [_]u64{ 0, 63, 64, 16383, 16384, (1 << 30) - 1, 1 << 30, webtransport.max_quic_varint };
    for (values) |value| {
        var encoded: [8]u8 = undefined;
        const length = try webtransport.encode_varint(value, &encoded);
        const decoded = try webtransport.decode_varint(encoded[0..length]);
        try std.testing.expectEqual(value, decoded.value);
        try std.testing.expectEqual(length, decoded.length);
    }

    const non_minimal = [_]u8{ 0x40, 0x25 };
    const decoded = try webtransport.decode_varint(&non_minimal);
    try std.testing.expectEqual(@as(u64, 0x25), decoded.value);
    try std.testing.expectEqual(@as(usize, 2), decoded.length);
}

test "phase3: WebTransport CONNECT rejects early and unauthorized sessions" {
    const valid = webtransport.ConnectRequest{
        .method = "CONNECT",
        .protocol = "webtransport-h3",
        .scheme = "https",
        .authority = "example.com",
        .path = "/transport",
        .origin = "https://example.com",
        .browser_client = true,
        .origin_allowed = true,
        .client_settings_received = true,
        .client_requirements_valid = true,
    };
    try webtransport.validate_connect(valid);

    var invalid = valid;
    invalid.arrived_before_confirmation = true;
    try std.testing.expectError(error.TooEarly, webtransport.validate_connect(invalid));
    invalid = valid;
    invalid.origin_allowed = false;
    try std.testing.expectError(error.ForbiddenOrigin, webtransport.validate_connect(invalid));
}

test "phase3: session slots reject stale handles after reuse" {
    const Sessions = webtransport.session_slab(1);
    var sessions = Sessions{};
    const first = try sessions.open(0, false);
    try sessions.establish(first);
    try std.testing.expectEqual(webtransport.SessionState.established, try sessions.state(first));
    try sessions.drain(first);
    try sessions.drain(first);
    try std.testing.expectError(error.InvalidTransition, sessions.establish(first));
    try sessions.close(first);
    try std.testing.expectEqual(@as(usize, 0), sessions.open_count());
    try std.testing.expectError(error.StaleHandle, sessions.state(first));

    const second = try sessions.open(4, false);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.StaleHandle, sessions.establish(first));
    try std.testing.expectEqual(second, sessions.find(4).?);
    try std.testing.expectEqual(@as(usize, 1), sessions.open_count());
    try std.testing.expectError(error.InvalidSessionId, sessions.open(5, true));

    try sessions.establish(second);
    try sessions.close(second);
    try std.testing.expectEqual(@as(usize, 0), sessions.open_count());
}

test "phase3: session admission enforces flow-control and capacity limits" {
    const Sessions = webtransport.session_slab(2);
    var sessions = Sessions{};
    const first = try sessions.open(0, false);
    try std.testing.expectError(error.TooManySessions, sessions.open(4, false));
    const second = try sessions.open(4, true);
    try std.testing.expectError(error.CapacityExceeded, sessions.open(8, true));
    try sessions.close(first);
    try sessions.close(second);
}

test "phase3: stream and datagram headers use the CONNECT session id" {
    var encoded: [64]u8 = undefined;
    const uni_length = try webtransport.encode_unidirectional_header(12, &encoded);
    const uni = try webtransport.decode_unidirectional_header(encoded[0..uni_length]);
    try std.testing.expectEqual(@as(u64, 12), uni.session_id);

    const bidi_length = try webtransport.encode_bidirectional_header(12, &encoded);
    const bidi = try webtransport.decode_bidirectional_header(encoded[0..bidi_length]);
    try std.testing.expectEqual(@as(u64, 12), bidi.session_id);

    const datagram_length = try webtransport.encode_datagram(12, "payload", &encoded);
    const datagram = try webtransport.decode_datagram(encoded[0..datagram_length]);
    try std.testing.expectEqual(@as(u64, 12), datagram.session_id);
    try std.testing.expectEqualStrings("payload", datagram.payload);
    try std.testing.expectEqual(@as(u64, 3), (try webtransport.decode_varint(encoded[0..1])).value);
}

test "phase3: pending association queues are fixed and fail closed" {
    const Pending = webtransport.pending_associations(1, 1, 8);
    var pending = Pending{};
    try pending.add_stream(4, 0, .bidirectional);
    try std.testing.expectError(
        error.BufferedStreamRejected,
        pending.add_stream(8, 0, .bidirectional),
    );
    try pending.add_datagram(0, "12345678");
    try std.testing.expectError(error.DropDatagram, pending.add_datagram(0, "x"));
    pending.clear();
    try std.testing.expectEqual(@as(usize, 0), pending.stream_count);
    try std.testing.expectEqual(@as(usize, 0), pending.datagram_count);
}

test "phase3: capsules enforce close and flow-control wire rules" {
    var encoded: [128]u8 = undefined;
    const close_length = try webtransport.encode_close_session(7, "done", &encoded);
    const decoded_close = try webtransport.decode_capsule(encoded[0..close_length]);
    switch (decoded_close.capsule) {
        .close_session => |close| {
            try std.testing.expectEqual(@as(u32, 7), close.application_error);
            try std.testing.expectEqualStrings("done", close.message);
        },
        else => return error.TestUnexpectedResult,
    }

    const drain_length = try webtransport.encode_drain_session(&encoded);
    const decoded_drain = try webtransport.decode_capsule(encoded[0..drain_length]);
    switch (decoded_drain.capsule) {
        .drain_session => {},
        else => return error.TestUnexpectedResult,
    }

    const max_length = try webtransport.encode_integer_capsule(webtransport.wt_max_data, 1024, &encoded);
    const decoded_max = try webtransport.decode_capsule(encoded[0..max_length]);
    var flow = webtransport.FlowState{};
    try std.testing.expectEqual(
        webtransport.CapsuleAction.applied,
        try webtransport.apply_capsule(&flow, decoded_max.capsule, true),
    );
    try std.testing.expectEqual(@as(u64, 1024), flow.max_data);
    try std.testing.expectError(
        error.FlowControlViolation,
        webtransport.apply_capsule(&flow, decoded_max.capsule, true),
    );
}

test "phase3: application error mapping skips HTTP/3 grease values" {
    const values = [_]u32{ 0, 1, 29, 30, 31, std.math.maxInt(u32) };
    for (values) |value| {
        const http3_error = webtransport.application_error_to_http3(value);
        try std.testing.expect((http3_error - 0x21) % 0x1f != 0);
        try std.testing.expectEqual(value, webtransport.http3_error_to_application(http3_error).?);
    }
}
