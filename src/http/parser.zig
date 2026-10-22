const std = @import("std");
const simd = @import("../core/simd.zig");
/// Request view populated by `consume`.
pub const Request = @import("request.zig").Request;

/// Incremental state of the bounded HTTP/1.1 request parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    headers,
    body,
    chunk_size,
    chunk_ext,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    done,
    error_invalid,
    error_headers_too_large,
    error_too_large,
};

/// Maximum accepted request-line length in bytes.
pub const max_request_line_size = 8 * 1024;
/// Maximum accepted header block length in bytes.
pub const max_header_size = 16 * 1024;
/// Default maximum accepted fixed or decoded chunked body length in bytes.
pub const default_max_body_size = 16 * 1024;
/// Default body limit kept for callers that do not configure a policy.
pub const max_body_size = default_max_body_size;

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn is_decimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn is_hexadecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// Routeable path and query derived from one request target.
const TargetView = struct {
    path: []const u8,
    query: []const u8,
};

/// Maps one RFC 9112 request-target to its routeable path and query.
///
/// Origin-form and absolute-form carry a path; asterisk-form is legal only
/// for OPTIONS and routes as the literal `*`. Authority-form (CONNECT),
/// unknown schemes, fragments, and userinfo fail closed because the router
/// has no authority view to match against.
fn parse_request_target(method: []const u8, target: []const u8) ?TargetView {
    if (target.len == 0) return null;
    for (target) |c| {
        if (c < 32 or c == 127) return null;
    }
    if (target[0] == '/') return split_target_query(target);
    if (std.mem.eql(u8, target, "*")) {
        if (!std.mem.eql(u8, method, "OPTIONS")) return null;
        return .{ .path = target, .query = "" };
    }
    return parse_absolute_target(target);
}

/// Splits an origin-form path at its first `?` and rejects fragments.
fn split_target_query(path: []const u8) ?TargetView {
    if (std.mem.indexOfScalar(u8, path, '#') != null) return null;
    if (std.mem.indexOfScalar(u8, path, '?')) |query_start| {
        return .{
            .path = path[0..query_start],
            .query = path[query_start + 1 ..],
        };
    }
    return .{ .path = path, .query = "" };
}

/// Parses an absolute-form `http`/`https` target into path and query.
///
/// RFC 9112 section 3.2.2 requires servers to accept absolute-form; the
/// authority must be present because the router only sees the path. An
/// empty URI path routes as `/`.
fn parse_absolute_target(target: []const u8) ?TargetView {
    if (std.mem.indexOfScalar(u8, target, '#') != null) return null;

    const scheme_end = std.mem.indexOf(u8, target, "://") orelse return null;
    const scheme = target[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and
        !std.ascii.eqlIgnoreCase(scheme, "https"))
    {
        return null;
    }

    const authority_start = scheme_end + "://".len;
    const boundary = std.mem.indexOfAnyPos(u8, target, authority_start, "/?") orelse
        target.len;
    const authority = target[authority_start..boundary];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) {
        return null;
    }
    if (boundary == target.len) return .{ .path = "/", .query = "" };
    if (target[boundary] == '?') {
        return .{ .path = "/", .query = target[boundary + 1 ..] };
    }
    return split_target_query(target[boundary..]);
}

/// Allocation-free incremental HTTP/1.1 parser state.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
    /// Absolute input offset where the next delimiter search resumes.
    scan: usize = 0,
    /// Bytes examined by delimiter searches for the current request.
    scan_work: usize = 0,
    content_length: usize = 0,
    chunk_length: usize = 0,
    body_length: usize = 0,
    body_start: usize = 0,
    /// Per-connection body policy; the owner's request buffer must be at least
    /// this large plus request-line, header, and framing slack.
    max_body_size: usize = default_max_body_size,
    /// Per-connection request-line policy.
    max_request_line_bytes: usize = max_request_line_size,
    /// Per-connection header-block policy.
    max_header_bytes: usize = max_header_size,
    /// Overflow storage for headers beyond the inline `Request` arrays.
    ///
    /// Both slices must be the same length and stay valid for the connection
    /// lifetime; an owner that supplies none fails closed at the inline cap.
    extra_header_names: [][]const u8 = &.{},
    extra_header_values: [][]const u8 = &.{},
    extra_header_count: usize = 0,
};

/// Enters `state` with the next token starting at `offset`.
///
/// The scan cursor restarts at the new token so the previous token's search
/// cannot leak into the next one.
fn enter_state(parser: *HttpParser, state: ParserState, offset: usize) void {
    parser.state = state;
    parser.mark = offset;
    parser.scan = offset;
}

/// Parses bytes into `req` and returns the prefix consumed by this request.
///
/// Request slices borrow `buffer`. Chunked bodies are compacted in place, so
/// callers must retain the mutable buffer until request dispatch completes.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []u8) usize {
    while (parser.mark < buffer.len) {
        switch (parser.state) {
            .method => {
                const search_start = parser.scan;
                if (std.mem.indexOfScalar(u8, buffer[search_start..], ' ')) |space_idx| {
                    parser.scan_work += space_idx + 1;
                    const abs_space = search_start + space_idx;
                    if (abs_space > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    if (abs_space == parser.mark) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    for (buffer[parser.mark..abs_space]) |c| {
                        if (!is_tchar(c)) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    req.method = buffer[parser.mark..abs_space];
                    enter_state(parser, .path, abs_space + 1);
                } else {
                    const pending = buffer.len - search_start;
                    parser.scan_work += pending;
                    // The CRLF pass keeps the existing error precedence: a
                    // bare CR or LF before the missing space is invalid.
                    if (std.mem.indexOfAny(u8, buffer[search_start..], "\r\n")) |crlf_idx| {
                        parser.scan_work += crlf_idx + 1;
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    parser.scan_work += pending;
                    if (buffer.len > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                    }
                    parser.scan = buffer.len;
                    return buffer.len; // need more data
                }
            },
            .path => {
                const search_start = parser.scan;
                if (std.mem.indexOfScalar(u8, buffer[search_start..], ' ')) |space_idx| {
                    parser.scan_work += space_idx + 1;
                    const abs_space = search_start + space_idx;
                    const target = buffer[parser.mark..abs_space];
                    if (abs_space > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    const view = parse_request_target(req.method, target) orelse {
                        parser.state = .error_invalid;
                        return buffer.len;
                    };
                    req.target = target;
                    req.path = view.path;
                    req.query = view.query;
                    enter_state(parser, .protocol, abs_space + 1);
                } else {
                    const pending = buffer.len - search_start;
                    parser.scan_work += pending;
                    if (std.mem.indexOfAny(u8, buffer[search_start..], "\r\n")) |crlf_idx| {
                        parser.scan_work += crlf_idx + 1;
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    parser.scan_work += pending;
                    if (buffer.len > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                    }
                    parser.scan = buffer.len;
                    return buffer.len;
                }
            },
            .protocol => {
                const search_start = parser.scan;
                if (std.mem.indexOfScalar(u8, buffer[search_start..], '\n')) |nl_idx| {
                    parser.scan_work += nl_idx + 1;
                    const abs_nl = search_start + nl_idx;
                    if (abs_nl + 1 > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    if (abs_nl > parser.mark and buffer[abs_nl - 1] == '\r') {
                        const proto = buffer[parser.mark .. abs_nl - 1];
                        if (!std.mem.eql(u8, proto, "HTTP/1.1")) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        enter_state(parser, .headers, abs_nl + 1);
                    } else {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                } else {
                    parser.scan_work += buffer.len - search_start;
                    if (buffer.len > parser.max_request_line_bytes) {
                        parser.state = .error_headers_too_large;
                    }
                    parser.scan = buffer.len;
                    return buffer.len;
                }
            },
            .headers => {
                const search_start = parser.scan;
                if (simd.index_of_header_end(buffer[search_start..])) |offset| {
                    parser.scan_work += offset + 4;
                    const end = search_start + offset;
                    if (end - parser.mark > parser.max_header_bytes) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }

                    var lines = std.mem.splitSequence(u8, buffer[parser.mark..end], "\r\n");
                    var has_host = false;
                    var has_cl = false;
                    var has_te = false;
                    var cl_too_large = false;

                    while (lines.next()) |line| {
                        if (line.len == 0) continue;
                        if (std.mem.indexOf(u8, line, ":")) |colon| {
                            const name = line[0..colon];
                            if (name.len == 0) {
                                parser.state = .error_invalid;
                                return buffer.len;
                            }
                            for (name) |c| {
                                if (!is_tchar(c)) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            var val_start = colon + 1;
                            while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) {
                                val_start += 1;
                            }

                            var val_end = line.len;
                            while (val_end > val_start and (line[val_end - 1] == ' ' or line[val_end - 1] == '\t')) {
                                val_end -= 1;
                            }

                            const value = line[val_start..val_end];

                            if (!simd.valid_http_field_value(value)) {
                                parser.state = .error_invalid;
                                return buffer.len;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Host")) {
                                if (has_host or value.len == 0) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_host = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                                if (has_te or !std.ascii.eqlIgnoreCase(value, "chunked")) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_te = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                                if (has_cl) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_cl = true;
                                if (!is_decimal(value)) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                if (std.fmt.parseInt(usize, value, 10)) |len| {
                                    if (len > parser.max_body_size) {
                                        cl_too_large = true;
                                    } else {
                                        parser.content_length = len;
                                    }
                                } else |_| {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            if (req.header_count >= req.header_names.len) {
                                if (parser.extra_header_count >= parser.extra_header_names.len) {
                                    parser.state = .error_headers_too_large;
                                    return buffer.len;
                                }
                                parser.extra_header_names[parser.extra_header_count] = name;
                                parser.extra_header_values[parser.extra_header_count] = value;
                                parser.extra_header_count += 1;
                            } else {
                                req.header_names[req.header_count] = name;
                                req.header_values[req.header_count] = value;
                                req.header_count += 1;
                            }
                        } else {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }

                    if (!has_host) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    // The framing conflict is invalid regardless of the
                    // declared length, so it wins over the body-limit check.
                    if (has_te and has_cl) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    if (cl_too_large) {
                        parser.state = .error_too_large;
                        return buffer.len;
                    }

                    req.extra_header_names = parser.extra_header_names[0..parser.extra_header_count];
                    req.extra_header_values = parser.extra_header_values[0..parser.extra_header_count];
                    req.extra_header_count = parser.extra_header_count;

                    if (has_te) {
                        enter_state(parser, .chunk_size, end + 4);
                        parser.body_start = parser.mark;
                        parser.body_length = 0;
                        continue;
                    }

                    if (parser.content_length > 0) {
                        enter_state(parser, .body, end + 4);
                        continue;
                    }

                    enter_state(parser, .done, end + 4);
                    return parser.mark;
                } else {
                    parser.scan_work += buffer.len - search_start;
                    if (buffer.len - parser.mark > parser.max_header_bytes) {
                        parser.state = .error_headers_too_large;
                    }
                    // The four-byte terminator may straddle the delivery
                    // boundary, so keep a three-byte overlap.
                    parser.scan = @max(parser.mark, buffer.len -| 3);
                    return buffer.len;
                }
            },
            .body => {
                const remaining = buffer.len - parser.mark;
                if (remaining >= parser.content_length) {
                    const body_end = parser.mark + parser.content_length;
                    req.body = buffer[parser.mark..body_end];
                    enter_state(parser, .done, body_end);
                    return parser.mark;
                } else {
                    return buffer.len;
                }
            },
            .chunk_size => {
                const search_start = parser.scan;
                if (std.mem.indexOfAny(u8, buffer[search_start..], "\r;")) |offset| {
                    parser.scan_work += offset + 1;
                    const end_idx = search_start + offset;
                    const hex_str = buffer[parser.mark..end_idx];
                    if (!is_hexadecimal(hex_str)) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    if (std.fmt.parseInt(usize, hex_str, 16)) |len| {
                        if (parser.body_length > parser.max_body_size or
                            len > parser.max_body_size - parser.body_length)
                        {
                            parser.state = .error_too_large;
                            return buffer.len;
                        }
                        parser.chunk_length = len;
                        if (buffer[end_idx] == ';') {
                            enter_state(parser, .chunk_ext, end_idx + 1);
                        } else {
                            if (end_idx + 1 < buffer.len) {
                                if (buffer[end_idx + 1] != '\n') {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                if (len == 0) {
                                    enter_state(parser, .chunk_trailer, end_idx + 2);
                                } else {
                                    enter_state(parser, .chunk_data, end_idx + 2);
                                }
                            } else {
                                // The CR and LF may arrive separately.
                                parser.scan = end_idx;
                                return buffer.len;
                            }
                        }
                        continue;
                    } else |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                }
                parser.scan_work += buffer.len - search_start;
                parser.scan = buffer.len;
                return buffer.len;
            },
            .chunk_ext => {
                const search_start = parser.scan;
                if (std.mem.indexOfScalar(u8, buffer[search_start..], '\r')) |offset| {
                    parser.scan_work += offset + 1;
                    const end_idx = search_start + offset;
                    for (buffer[parser.mark..end_idx]) |c| {
                        if ((c < 32 and c != '\t') or c == 127) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    if (end_idx + 1 < buffer.len) {
                        if (buffer[end_idx + 1] != '\n') {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        if (parser.chunk_length == 0) {
                            enter_state(parser, .chunk_trailer, end_idx + 2);
                        } else {
                            enter_state(parser, .chunk_data, end_idx + 2);
                        }
                        continue;
                    } else {
                        // The CR and LF may arrive separately.
                        parser.scan = end_idx;
                        return buffer.len;
                    }
                }
                parser.scan_work += buffer.len - search_start;
                parser.scan = buffer.len;
                return buffer.len;
            },
            .chunk_data => {
                const available = buffer.len - parser.mark;
                if (available >= parser.chunk_length) {
                    const chunk_end = parser.mark + parser.chunk_length;
                    const src = buffer[parser.mark..chunk_end];
                    const dst = buffer[parser.body_start + parser.body_length .. parser.body_start + parser.body_length + parser.chunk_length];
                    std.mem.copyForwards(u8, dst, src);
                    parser.body_length += parser.chunk_length;
                    enter_state(parser, .chunk_crlf, chunk_end);
                    continue;
                }
                return buffer.len;
            },
            .chunk_crlf => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] != '\r' or buffer[parser.mark + 1] != '\n') {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    enter_state(parser, .chunk_size, parser.mark + 2);
                    continue;
                }
                return buffer.len;
            },
            .chunk_trailer => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] == '\r' and buffer[parser.mark + 1] == '\n') {
                        req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                        enter_state(parser, .done, parser.mark + 2);
                        return parser.mark;
                    }
                }
                const search_start = parser.scan;
                if (simd.index_of_header_end(buffer[search_start..])) |relative_end| {
                    parser.scan_work += relative_end + 4;
                    const end_idx = search_start + relative_end;
                    if (!valid_trailers(buffer[parser.mark..end_idx], parser.max_header_bytes)) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                    enter_state(parser, .done, end_idx + 4);
                    return parser.mark;
                }
                parser.scan_work += buffer.len - search_start;
                // The four-byte terminator may straddle the delivery
                // boundary, so keep a three-byte overlap.
                parser.scan = @max(parser.mark, buffer.len -| 3);
                return buffer.len;
            },
            .done, .error_invalid, .error_headers_too_large, .error_too_large => return parser.mark,
        }
    }

    return parser.mark;
}

fn valid_trailers(trailers: []const u8, max_bytes: usize) bool {
    if (trailers.len > max_bytes) return false;

    var field_count: usize = 0;
    var lines = std.mem.splitSequence(u8, trailers, "\r\n");
    while (lines.next()) |line| {
        field_count += 1;
        if (field_count > 64) return false;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const name = line[0..colon];
        if (name.len == 0) return false;
        for (name) |c| {
            if (!is_tchar(c)) return false;
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Length") or
            std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(name, "Host"))
        {
            return false;
        }

        for (line[colon + 1 ..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
        }
    }
    return true;
}

/// Resets parser offsets and lengths before parsing the next request.
pub fn reset(parser: *HttpParser) void {
    parser.extra_header_count = 0;
    parser.state = .method;
    parser.mark = 0;
    parser.scan = 0;
    parser.scan_work = 0;
    parser.content_length = 0;
    parser.chunk_length = 0;
    parser.body_length = 0;
    parser.body_start = 0;
}
