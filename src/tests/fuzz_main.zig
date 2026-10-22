const std = @import("std");
const support = @import("test_support");
const parser = support.http_parser;
const Request = parser.Request;
const zslay = @import("zslay");
const ws_handshake = support.ws_handshake;
const quic_validation = support.quic_validation;
const json_rpc = support.json_rpc;
const query = support.query;
const cookie = support.cookie;
const negotiate = support.negotiate;
const hpack = support.http2_hpack;
const multipart = support.multipart;

test "fuzz: protocol parsers preserve bounded state" {
    try std.testing.fuzz({}, fuzz_protocol_parsers, .{
        .corpus = &.{
            "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ntest",
            "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n",
            "invalid",
            "\x81\x80\x01\x02\x03\x04",
            "\x89\x80\x01\x02\x03\x04",
            "\x88\x82\x01\x02\x03\x04\x02\xea",
            "\xff\xff\xff\xff",
            "{\"jsonrpc\":\"2.0\",\"method\":\"echo\",\"id\":1}",
            "[{\"jsonrpc\":\"2.0\",\"method\":\"echo\"},17]",
            "[{\"jsonrpc\":\"2.0\",\"method\":\"echo\",\"id\":1},",
            "session=abc; theme=dark; empty=; broken; =x",
            // HPACK: RFC 7541 C.3 and C.4 request vectors, a table-size update,
            // a truncated literal, and a dynamic insert followed by an index.
            "\x82\x86\x84\x41\x0fwww.example.com",
            "\x82\x86\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff",
            "\x3f\xe1\x1f",
            "\x00\x05\x01",
            "\x40\x0acustom-key\x05value\xbe",
            // Multipart: valid part, preamble and epilogue, truncated body,
            // and nested-looking boundary text inside part data.
            "multipart/form-data; boundary=abc\r\n--abc\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ndata\r\n--abc--\r\n",
            "multipart/form-data; boundary=abc\r\npreamble\r\n--abc\r\nContent-Disposition: form-data; name=\"a\"; filename=\"f.txt\"\r\nContent-Type: text/plain\r\n\r\naaaa\r\n--abc\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nbbbb\r\n--abc--\r\nepilogue",
            "multipart/form-data; boundary=abc\r\n--abc\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ntruncated",
            "multipart/form-data; boundary=abc\r\n--abc\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nnested--abc inside\r\n--abc--",
        },
    });
}

fn fuzz_protocol_parsers(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    try fuzz_http_parser(smith);
    try fuzz_http_query(smith);
    try fuzz_cookie_jar(smith);
    try fuzz_zslay_receive(smith);
    fuzz_extension_negotiation(smith);
    fuzz_http3_validation(smith);
    try fuzz_json_rpc(smith);
    try fuzz_hpack_decode(smith);
    try fuzz_multipart_parse(smith);
}

fn fuzz_http_query(smith: *std.testing.Smith) !void {
    var input: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '?', 8),
        .value(u8, '&', 8),
        .value(u8, '=', 8),
        .value(u8, '%', 8),
        .value(u8, '+', 8),
        .value(u8, 0xff, 1),
    }));
    const bytes = input[0..input_len];

    const start = @intFromPtr(bytes.ptr);
    const end = start + bytes.len;
    const params = query.QueryParams.parse_link(bytes) catch return;
    try std.testing.expect(params.count <= query.max_params);

    var scratch: [1024]u8 = undefined;
    var pairs = params.pairs();
    while (pairs.next()) |pair| {
        try std.testing.expect(@intFromPtr(pair.key.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.key.ptr) + pair.key.len <= end);
        try std.testing.expect(@intFromPtr(pair.value.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.value.ptr) + pair.value.len <= end);
        _ = query.percent_decode(pair.key, &scratch) catch {};
        _ = query.form_decode(pair.value, &scratch) catch {};
    }

    const accept = negotiate.parse(bytes);
    try std.testing.expect(accept.count <= negotiate.max_entries);
    _ = negotiate.best(accept, &.{ "application/json", "text/html" });
}

fn fuzz_cookie_jar(smith: *std.testing.Smith) !void {
    var input: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, ';', 8),
        .value(u8, '=', 8),
        .value(u8, ' ', 4),
        .value(u8, 0x00, 1),
    }));
    const bytes = input[0..input_len];

    const start = @intFromPtr(bytes.ptr);
    const end = start + bytes.len;
    const jar = cookie.CookieJar.parse(bytes);
    try std.testing.expect(jar.count <= cookie.max_cookies);

    var pair_count: usize = 0;
    var pairs = jar.pairs();
    while (pairs.next()) |pair| {
        pair_count += 1;
        try std.testing.expect(@intFromPtr(pair.name.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.name.ptr) + pair.name.len <= end);
        try std.testing.expect(@intFromPtr(pair.value.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.value.ptr) + pair.value.len <= end);
    }
    try std.testing.expectEqual(jar.count, pair_count);
    try std.testing.expect(jar.at(jar.count) == null);

    // The jar must match the scalar reference for every pair it stores.
    var scalar = cookie.iterator(bytes);
    var index: usize = 0;
    while (index < jar.count) : (index += 1) {
        const expected = scalar.next().?;
        const stored = jar.at(index).?;
        try std.testing.expectEqualStrings(expected.name, stored.name);
        try std.testing.expectEqualStrings(expected.value, stored.value);
    }
    if (jar.count < cookie.max_cookies) try std.testing.expect(scalar.next() == null);
}

fn rpc_echo(call: *json_rpc.Call) json_rpc.HandlerError!void {
    try call.result(null);
}

fn fuzz_json_rpc(smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const input_length: usize = @intCast(smith.slice(&input));
    const RpcService = json_rpc.configured_service(1, 16, 4096);
    var service = RpcService{};
    try service.register("echo", rpc_echo);

    var output: [4096]u8 = undefined;
    const response = service.dispatch(input[0..input_length], &output) catch return;
    const payload = response orelse return;
    if (payload.len > output.len) @panic("JSON-RPC response escaped output storage");

    var scanner_scratch: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scanner_scratch);
    var scanner = std.json.Scanner.initCompleteInput(scratch.allocator(), payload);
    defer scanner.deinit();
    scanner.skipValue() catch @panic("JSON-RPC emitted invalid JSON");
    switch (scanner.next() catch @panic("JSON-RPC response did not terminate")) {
        .end_of_document => {},
        else => @panic("JSON-RPC emitted trailing JSON"),
    }
}

fn fuzz_http3_validation(smith: *std.testing.Smith) void {
    var input: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input));
    const split = smith.index(input_len + 1);
    const first = input[0..split];
    const second = input[split..input_len];

    _ = quic_validation.valid_method(first);
    _ = quic_validation.valid_target(first);
    _ = quic_validation.valid_authority(first);
    _ = quic_validation.valid_http3_name(first);
    _ = quic_validation.valid_header_value(second);
    _ = quic_validation.connection_specific_header(first);
    _ = quic_validation.parse_decimal(second);
}

fn fuzz_extension_negotiation(smith: *std.testing.Smith) void {
    var input: [512]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, ';', 8),
        .value(u8, ',', 8),
        .value(u8, '=', 8),
        .value(u8, '"', 4),
    }));
    _ = ws_handshake.negotiate_permessage_deflate(input[0..input_len]);
}

fn fuzz_http_parser(smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '\r', 8),
        .value(u8, '\n', 8),
        .value(u8, ':', 4),
    }));
    const split = smith.index(input_len + 1);

    var p = parser.HttpParser{};
    var req = Request{};
    _ = parser.consume(&p, &req, input[0..split]);
    if (!parser_is_terminal(p.state)) {
        const consumed = parser.consume(&p, &req, input[0..input_len]);
        try std.testing.expect(consumed <= input_len);
    }

    // Incremental delivery must not re-examine the whole prefix per call.
    try std.testing.expect(p.scan_work <= 4 * input_len + 32);
    try std.testing.expect(req.header_count <= req.header_names.len);
    try std.testing.expect(req.body.len <= parser.max_body_size);
}

fn parser_is_terminal(state: parser.ParserState) bool {
    return switch (state) {
        .done, .error_invalid, .error_headers_too_large, .error_too_large => true,
        else => false,
    };
}

fn fuzz_hpack_decode(smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x80, 8),
        .value(u8, 0x40, 8),
        .value(u8, 0x20, 4),
    }));
    const block = input[0..input_len];

    var entries: [32]hpack.DynamicEntry = undefined;
    var table_storage: [1024]u8 = undefined;
    var table = try hpack.DynamicTable.init(&entries, &table_storage, 256);
    var decoder = hpack.Decoder.init(&table, 4096);

    var headers: [16]hpack.Header = undefined;
    var header_storage: [4096]u8 = undefined;
    const decoded = decoder.decode_fields(block, &headers, &header_storage) catch return;
    try std.testing.expect(decoded.len <= headers.len);
    for (decoded) |header| {
        try std.testing.expect(slice_within_buffer(&header_storage, header.name));
        try std.testing.expect(slice_within_buffer(&header_storage, header.value));
    }

    // A fresh table keeps request validation independent of the mutations
    // applied above.
    var request_entries: [32]hpack.DynamicEntry = undefined;
    var request_table_storage: [1024]u8 = undefined;
    var request_table = try hpack.DynamicTable.init(&request_entries, &request_table_storage, 256);
    var request_decoder = hpack.Decoder.init(&request_table, 4096);
    var request_storage: [4096]u8 = undefined;
    const request = request_decoder.decode_request(block, &headers, &request_storage) catch return;
    try std.testing.expect(request.headers.len <= headers.len);
    for (request.headers) |header| {
        try std.testing.expect(slice_within_buffer(&request_storage, header.name));
        try std.testing.expect(slice_within_buffer(&request_storage, header.value));
    }
}

fn fuzz_multipart_parse(smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '\r', 8),
        .value(u8, '\n', 8),
        .value(u8, '-', 8),
        .value(u8, ';', 4),
        .value(u8, '=', 4),
        .value(u8, '"', 2),
        .value(u8, 0x00, 1),
    }));
    const bytes = input[0..input_len];
    const split = smith.index(input_len + 1);
    const content_type = bytes[0..split];
    const body = bytes[split..];

    const boundary = multipart.boundary_from_content_type(content_type) catch return;
    var multipart_parser = try multipart.Parser.init(body, boundary);

    var part_count: usize = 0;
    while (part_count < 64) : (part_count += 1) {
        const next = multipart_parser.next_part() catch return;
        const part = next orelse break;
        try std.testing.expect(slice_within_buffer(body, part.headers));
        try std.testing.expect(slice_within_buffer(body, part.name));
        try std.testing.expect(slice_within_buffer(body, part.data));
        if (part.filename) |filename| {
            try std.testing.expect(slice_within_buffer(body, filename));
        }
        if (part.content_type) |value| {
            try std.testing.expect(slice_within_buffer(body, value));
        }

        var chunks = part.chunks(7);
        while (chunks.next()) |chunk| {
            try std.testing.expect(slice_within_buffer(part.data, chunk));
        }
    }
}

fn slice_within_buffer(buffer: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(buffer.ptr);
    const end = start + buffer.len;
    const slice_start = @intFromPtr(slice.ptr);
    return slice_start >= start and slice_start + slice.len <= end;
}

fn fuzz_zslay_receive(smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Smith generates malformed frames, so parser errors end the current sample.
    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input));
    var nodes: [4]zslay.FrameNode = undefined;
    var conn = zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = input.len,
        .max_message_len = input.len,
    }) catch return;

    var offset: usize = 0;
    var steps: usize = 0;
    while (steps < input_len * 3 + 32) : (steps += 1) {
        const action = conn.advance_rx() catch return;
        switch (action) {
            .need_header => {
                if (offset == input_len) return;
                const destination = conn.get_header_buffer();
                const copy_len = @min(destination.len, input_len - offset);
                @memcpy(destination[0..copy_len], input[offset .. offset + copy_len]);
                conn.advance_header_read(copy_len) catch return;
                offset += copy_len;
            },
            .need_payload => {
                if (offset == input_len) return;
                const decoded = conn.decoded_header orelse return;
                const remaining = decoded.payload_len - conn.payload_bytes_processed;
                const available: u64 = @intCast(input_len - offset);
                const copy_len = @min(remaining, available);
                conn.advance_payload_read(copy_len) catch return;
                offset += @intCast(copy_len);
            },
            .emit_frame => conn.complete_frame(),
            else => return,
        }
    }

    try std.testing.expect(steps < input_len * 3 + 32);
}
