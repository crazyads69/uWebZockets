const parser = @import("fuzz_support").http_parser;

const max_input_size = parser.max_request_line_size +
    parser.max_header_size +
    parser.max_body_size +
    1024;

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;

    var storage: [max_input_size]u8 = undefined;
    @memcpy(storage[0..input.len], input);
    const buffer = storage[0..input.len];
    const split = if (input.len == 0) 0 else @as(usize, input[0]) % (input.len + 1);

    var state = parser.HttpParser{};
    var request = parser.Request{};
    const first_consumed = parser.consume(&state, &request, buffer[0..split]);
    enforce_invariants(first_consumed, split, state.scan_work, &request);

    if (!terminal(state.state)) {
        const consumed = parser.consume(&state, &request, buffer);
        enforce_invariants(consumed, buffer.len, state.scan_work, &request);
    }
}

export fn LLVMFuzzerTestOneInput(
    data: [*]const u8,
    size: usize,
) callconv(.c) c_int {
    if (size <= max_input_size) fuzz_one(data[0..size]);
    return 0;
}

fn enforce_invariants(
    consumed: usize,
    available: usize,
    scan_work: usize,
    request: *const parser.Request,
) void {
    if (consumed > available) @panic("HTTP parser consumed beyond input");
    if (scan_work > 4 * available + 32) @panic("HTTP parser delimiter scan work is superlinear");
    if (request.header_count > request.header_names.len) @panic("HTTP header count overflow");
    if (request.body.len > parser.max_body_size) @panic("HTTP body bound exceeded");
}

fn terminal(state: parser.ParserState) bool {
    return switch (state) {
        .done, .error_invalid, .error_headers_too_large, .error_too_large => true,
        else => false,
    };
}
