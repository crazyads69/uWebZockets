//! Pure incremental HTTP/1.1 response parser.
//!
//! The parser borrows a caller-owned accumulator buffer, decodes chunked
//! bodies in place, and performs no I/O, allocation, logging, or clock access.
//! It always requests `Connection: close` semantics from the owning transport,
//! so message framing never depends on connection reuse.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("types.zig");

const Header = types.Header;
/// Borrowed view of a completed response, re-exported for the transport.
pub const ResponseView = types.ResponseView;

/// Maximum accepted response head fields. Trailer fields are validated
/// against the same bound independently, so a response may carry up to this
/// many head fields and this many trailer fields.
pub const max_header_fields = types.max_response_header_fields;
/// Maximum accepted response head, including the status line.
pub const max_head_bytes = types.max_response_head_bytes;
/// Maximum accepted trailer block.
pub const max_trailer_bytes = 8 * 1024;
/// Interim `100 Continue` responses tolerated per fetch.
pub const max_interim_responses = 8;

/// Why a response could not be parsed.
pub const ParseFailure = enum {
    malformed,
    head_too_large,
    too_many_headers,
    body_too_large,
    trailer_too_large,
    unsupported_transfer_encoding,
    conflicting_framing,
    unexpected_interim,
};

/// Parser position.
pub const State = enum {
    status_line,
    interim_headers,
    headers,
    fixed_body,
    chunk_size,
    chunk_size_end,
    chunk_ext,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    eof_body,
    done,
};

/// Outcome of one incremental parse step.
pub const Progress = union(enum) {
    need_more,
    complete: ResponseView,
    failed: ParseFailure,
};

/// Error set of `copy_view`.
pub const CopyError = error{BufferOverflow};

/// Allocation-free incremental HTTP/1.1 response parser.
pub const Parser = struct {
    state: State = .status_line,
    /// Next unparsed raw byte in the accumulator.
    mark: usize = 0,
    /// Absolute input offset where the next delimiter search resumes.
    scan: usize = 0,
    /// Bytes examined by delimiter searches for the current response.
    scan_work: usize = 0,
    /// First decoded body byte.
    body_start: usize = 0,
    /// Decoded body byte count.
    body_length: usize = 0,
    content_length: usize = 0,
    chunk_length: usize = 0,
    body_capacity: usize = 0,
    head_limit: usize = max_head_bytes,
    status: u16 = 0,
    header_count: usize = 0,
    interim_count: usize = 0,
    request_is_head: bool = false,
    head_complete: bool = false,
    failure: ?ParseFailure = null,
    headers: [max_header_fields]Header = undefined,

    /// Prepares a parser with the decoded body bound for one fetch.
    pub fn init(body_capacity: usize, request_is_head: bool) Parser {
        return .{
            .body_capacity = body_capacity,
            .request_is_head = request_is_head,
        };
    }

    /// Parses as much of `buffer[0..raw_len]` as forms a complete response.
    ///
    /// Chunked decoding compacts payload bytes toward `body_start`, so the
    /// caller must pass the same mutable buffer on every call.
    pub fn consume(self: *Parser, buffer: []u8, raw_len: usize) Progress {
        if (self.failure) |failure| return .{ .failed = failure };

        while (true) {
            const progress: ?Progress = switch (self.state) {
                .status_line => self.parse_status_line(buffer, raw_len),
                .interim_headers => self.parse_interim_headers(buffer, raw_len),
                .headers => self.parse_headers(buffer, raw_len),
                .fixed_body => self.parse_fixed_body(buffer, raw_len),
                .chunk_size => self.parse_chunk_size(buffer, raw_len),
                .chunk_size_end => self.parse_chunk_size_end(buffer, raw_len),
                .chunk_ext => self.parse_chunk_ext(buffer, raw_len),
                .chunk_data => self.parse_chunk_data(buffer, raw_len),
                .chunk_crlf => self.parse_chunk_crlf(buffer, raw_len),
                .chunk_trailer => self.parse_chunk_trailer(buffer, raw_len),
                .eof_body => self.parse_eof_body(raw_len),
                .done => .{ .complete = self.view(buffer) },
            };
            if (progress) |result| return result;
        }
    }

    /// Completes an EOF-delimited body after the peer closes its write side.
    pub fn finish_eof(self: *Parser, buffer: []u8, raw_len: usize) Progress {
        if (self.failure) |failure| return .{ .failed = failure };
        switch (self.state) {
            .eof_body => {
                if (raw_len - self.body_start > self.body_capacity) {
                    return self.fail(.body_too_large);
                }
                self.body_length = raw_len - self.body_start;
                self.mark = raw_len;
                self.state = .done;
                return .{ .complete = self.view(buffer) };
            },
            .done => return .{ .complete = self.view(buffer) },
            else => return self.fail(.malformed),
        }
    }

    /// Reclaims consumed framing bytes by shifting the unconsumed tail down to
    /// the decoded body end and returns the new raw length.
    ///
    /// Only bytes after the head region move, so parsed header and body
    /// slices stay valid.
    pub fn compact(self: *Parser, buffer: []u8, raw_len: usize) usize {
        if (!self.head_complete or self.state == .done) return raw_len;
        const tail = self.body_start + self.body_length;
        if (self.mark <= tail) return raw_len;

        const shift = self.mark - tail;
        const remaining = raw_len - self.mark;
        std.mem.copyForwards(u8, buffer[tail .. tail + remaining], buffer[self.mark..raw_len]);
        self.mark = tail;
        // Rebase the scan cursor by the same shift, clamp it to the retained
        // range, and never let it move behind the new mark.
        self.scan = if (self.scan > shift) self.scan - shift else tail;
        self.scan = @max(self.scan, tail);
        const new_raw_len = tail + remaining;
        self.scan = @min(self.scan, new_raw_len);
        return new_raw_len;
    }

    /// Reports whether the head has been fully parsed.
    pub fn head_parsed(self: *const Parser) bool {
        return self.head_complete;
    }

    fn fail(self: *Parser, failure: ParseFailure) Progress {
        self.failure = failure;
        return .{ .failed = failure };
    }

    fn view(self: *const Parser, buffer: []u8) ResponseView {
        return .{
            .status = self.status,
            .headers = self.headers[0..self.header_count],
            .body = buffer[self.body_start .. self.body_start + self.body_length],
        };
    }

    fn parse_status_line(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        const start = @min(@max(self.mark, self.scan), raw_len);
        const search = buffer[start..raw_len];
        self.scan_work += search.len;
        const relative = std.mem.indexOfScalar(u8, search, '\n') orelse {
            self.scan = raw_len;
            if (raw_len > self.head_limit) return self.fail(.head_too_large);
            return .need_more;
        };
        const newline = start + relative;
        if (newline == self.mark or buffer[newline - 1] != '\r') return self.fail(.malformed);

        const line = buffer[self.mark .. newline - 1];
        const code = parse_status_code(line) orelse return self.fail(.malformed);
        self.mark = newline + 1;
        self.scan = self.mark;

        if (code < 200) {
            if (code != 100) return self.fail(.unexpected_interim);
            self.interim_count += 1;
            if (self.interim_count > max_interim_responses) {
                return self.fail(.unexpected_interim);
            }
            self.state = .interim_headers;
            return null;
        }

        self.status = code;
        self.state = .headers;
        return null;
    }

    fn parse_interim_headers(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.mark >= 2 and
            buffer[self.mark] == '\r' and
            buffer[self.mark + 1] == '\n')
        {
            self.mark += 2;
            self.scan = self.mark;
            self.state = .status_line;
            return null;
        }

        const end = self.find_header_end(buffer, raw_len) orelse {
            if (raw_len > self.head_limit) return self.fail(.head_too_large);
            return .need_more;
        };
        if (end > self.head_limit) return self.fail(.head_too_large);
        if (validate_field_lines(buffer[self.mark..end])) |failure| return self.fail(failure);

        self.mark = end + 4;
        self.scan = self.mark;
        self.state = .status_line;
        return null;
    }

    fn parse_headers(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        // An empty field section is just CRLF; otherwise the section ends at
        // the first CRLFCRLF.
        var end = self.mark;
        var head_end = self.mark;
        if (raw_len - self.mark >= 2 and
            buffer[self.mark] == '\r' and
            buffer[self.mark + 1] == '\n')
        {
            head_end = self.mark + 2;
        } else {
            const found = self.find_header_end(buffer, raw_len) orelse {
                if (raw_len > self.head_limit) return self.fail(.head_too_large);
                return .need_more;
            };
            end = found;
            head_end = found + 4;
        }
        if (head_end > self.head_limit) return self.fail(.head_too_large);

        var has_te = false;
        var has_cl = false;
        // A HEAD reply or a no-body status carries framing fields for
        // informational purposes only; their length never bounds storage.
        const body_forbidden = self.request_is_head or
            self.status == 204 or
            self.status == 205 or
            self.status == 304;
        var lines = std.mem.splitSequence(u8, buffer[self.mark..end], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return self.fail(.malformed);
            const name = line[0..colon];
            if (!valid_header_name(name)) return self.fail(.malformed);

            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (!simd.valid_http_field_value(value)) return self.fail(.malformed);

            if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                if (has_te or !std.ascii.eqlIgnoreCase(value, "chunked")) {
                    return self.fail(.unsupported_transfer_encoding);
                }
                has_te = true;
            }
            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                if (has_cl) return self.fail(.conflicting_framing);
                has_cl = true;
                if (!is_decimal(value)) return self.fail(.malformed);
                const length = std.fmt.parseInt(usize, value, 10) catch return self.fail(.malformed);
                if (!body_forbidden and length > self.body_capacity) {
                    return self.fail(.body_too_large);
                }
                self.content_length = length;
            }

            if (self.header_count >= max_header_fields) return self.fail(.too_many_headers);
            self.headers[self.header_count] = .{ .name = name, .value = value };
            self.header_count += 1;
        }

        if (has_te and has_cl) return self.fail(.conflicting_framing);

        self.head_complete = true;
        self.body_start = head_end;
        self.mark = head_end;
        self.scan = head_end;

        if (body_forbidden) {
            self.state = .done;
            return .{ .complete = self.view(buffer) };
        }
        if (has_te) {
            self.state = .chunk_size;
            return null;
        }
        if (has_cl) {
            if (self.content_length == 0) {
                self.state = .done;
                return .{ .complete = self.view(buffer) };
            }
            self.state = .fixed_body;
            return null;
        }
        self.state = .eof_body;
        return null;
    }

    fn parse_fixed_body(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.body_start < self.content_length) {
            // Keep the arrived prefix accounted so compaction is a no-op.
            self.body_length = raw_len - self.body_start;
            return .need_more;
        }
        self.body_length = self.content_length;
        self.mark = self.body_start + self.content_length;
        self.scan = self.mark;
        self.state = .done;
        return .{ .complete = self.view(buffer) };
    }

    fn parse_chunk_size(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        const start = @min(@max(self.mark, self.scan), raw_len);
        const search = buffer[start..raw_len];
        self.scan_work += search.len;
        const relative = simd.index_of_either_byte(search, '\r', ';') orelse {
            self.scan = raw_len;
            if (raw_len - self.mark > 1024) return self.fail(.malformed);
            return .need_more;
        };
        const end = start + relative;
        const hex = buffer[self.mark..end];
        if (hex.len == 0 or hex.len > 16) return self.fail(.malformed);
        for (hex) |byte| {
            if (!is_hexadecimal(byte)) return self.fail(.malformed);
        }
        const length = std.fmt.parseInt(u64, hex, 16) catch return self.fail(.malformed);
        if (length > self.body_capacity - self.body_length) return self.fail(.body_too_large);
        self.chunk_length = @intCast(length);
        self.mark = end;

        if (buffer[end] == ';') {
            self.mark += 1;
            self.scan = self.mark;
            self.state = .chunk_ext;
            return null;
        }
        self.mark = end;
        self.scan = end;
        self.state = .chunk_size_end;
        return null;
    }

    fn parse_chunk_ext(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        const start = @min(@max(self.mark, self.scan), raw_len);
        const search = buffer[start..raw_len];
        self.scan_work += search.len;
        const relative = simd.index_of_crlf(search) orelse {
            // Keep a one-byte overlap so a trailing CR is rechecked with the
            // next read instead of being skipped.
            self.scan = if (raw_len > start) raw_len - 1 else start;
            if (raw_len - self.mark > 1024) return self.fail(.malformed);
            return .need_more;
        };
        const end = start + relative;
        for (buffer[self.mark..end]) |byte| {
            if ((byte < 32 and byte != '\t') or byte == 127) return self.fail(.malformed);
        }
        self.mark = end + 2;
        self.scan = self.mark;
        if (self.chunk_length == 0) {
            self.state = .chunk_trailer;
            return null;
        }
        self.state = .chunk_data;
        return null;
    }

    fn parse_chunk_size_end(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.mark < 2) {
            self.scan = self.mark;
            return .need_more;
        }
        if (buffer[self.mark] != '\r' or buffer[self.mark + 1] != '\n') {
            return self.fail(.malformed);
        }
        self.mark += 2;
        self.scan = self.mark;
        if (self.chunk_length == 0) {
            self.state = .chunk_trailer;
            return null;
        }
        self.state = .chunk_data;
        return null;
    }

    fn parse_chunk_data(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.mark < self.chunk_length) return .need_more;

        const destination = self.body_start + self.body_length;
        std.mem.copyForwards(
            u8,
            buffer[destination .. destination + self.chunk_length],
            buffer[self.mark .. self.mark + self.chunk_length],
        );
        self.body_length += self.chunk_length;
        self.mark += self.chunk_length;
        self.scan = self.mark;
        self.state = .chunk_crlf;
        return null;
    }

    fn parse_chunk_crlf(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.mark < 2) {
            self.scan = self.mark;
            return .need_more;
        }
        if (buffer[self.mark] != '\r' or buffer[self.mark + 1] != '\n') {
            return self.fail(.malformed);
        }
        self.mark += 2;
        self.scan = self.mark;
        self.state = .chunk_size;
        return null;
    }

    fn parse_chunk_trailer(self: *Parser, buffer: []u8, raw_len: usize) ?Progress {
        if (raw_len - self.mark >= 2 and
            buffer[self.mark] == '\r' and
            buffer[self.mark + 1] == '\n')
        {
            self.mark += 2;
            self.scan = self.mark;
            self.state = .done;
            return .{ .complete = self.view(buffer) };
        }

        const end = self.find_header_end(buffer, raw_len) orelse {
            if (raw_len - self.mark > max_trailer_bytes) return self.fail(.trailer_too_large);
            return .need_more;
        };
        if (end - self.mark > max_trailer_bytes) return self.fail(.trailer_too_large);
        if (validate_trailers(buffer[self.mark..end])) |failure| return self.fail(failure);

        self.mark = end + 4;
        self.scan = self.mark;
        self.state = .done;
        return .{ .complete = self.view(buffer) };
    }

    fn parse_eof_body(self: *Parser, raw_len: usize) ?Progress {
        if (raw_len - self.body_start > self.body_capacity) return self.fail(.body_too_large);
        self.body_length = raw_len - self.body_start;
        self.mark = raw_len;
        return .need_more;
    }

    fn find_header_end(self: *Parser, buffer: []u8, raw_len: usize) ?usize {
        // Keep a three-byte overlap so a terminator split across reads is
        // found without rescanning the accumulated prefix.
        const start = @min(@max(self.mark, self.scan -| 3), raw_len);
        const search = buffer[start..raw_len];
        self.scan_work += search.len;
        const relative = simd.index_of_header_end(search) orelse {
            self.scan = raw_len;
            return null;
        };
        const end = start + relative;
        self.scan = end + 4;
        return end;
    }
};

/// Parses `HTTP/1.1 NNN [reason]` and returns the status code.
pub fn parse_status_code(line: []const u8) ?u16 {
    if (line.len < 12) return null;
    if (!std.mem.eql(u8, line[0..8], "HTTP/1.1")) return null;
    if (line[8] != ' ') return null;

    var code: u16 = 0;
    for (line[9..12]) |byte| {
        if (byte < '0' or byte > '9') return null;
        code = code * 10 + (byte - '0');
    }
    if (code < 100 or code > 599) return null;

    if (line.len == 12) return code;
    if (line[12] != ' ') return null;
    if (!simd.valid_http_field_value(line[13..])) return null;
    return code;
}

/// Validates a trailer block, rejecting fields that would change framing.
pub fn validate_trailers(trailers: []const u8) ?ParseFailure {
    if (trailers.len > max_trailer_bytes) return .trailer_too_large;

    var field_count: usize = 0;
    var lines = std.mem.splitSequence(u8, trailers, "\r\n");
    while (lines.next()) |line| {
        field_count += 1;
        if (field_count > max_header_fields) return .too_many_headers;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .malformed;
        const name = line[0..colon];
        if (!valid_header_name(name)) return .malformed;
        if (std.ascii.eqlIgnoreCase(name, "Content-Length") or
            std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(name, "Host"))
        {
            return .malformed;
        }
        if (!simd.valid_http_field_value(line[colon + 1 ..])) return .malformed;
    }
    return null;
}

/// Copies a response view into caller-owned storage, rebuilding header slices.
pub fn copy_view(
    view: ResponseView,
    headers_out: []Header,
    head_out: []u8,
    body_out: []u8,
) CopyError!ResponseView {
    var head_len: usize = 0;
    var header_count: usize = 0;
    for (view.headers) |header| {
        if (header_count >= headers_out.len) return error.BufferOverflow;
        const required = header.name.len + header.value.len;
        if (required > head_out.len - head_len) return error.BufferOverflow;

        @memcpy(head_out[head_len..][0..header.name.len], header.name);
        const name = head_out[head_len..][0..header.name.len];
        head_len += header.name.len;
        @memcpy(head_out[head_len..][0..header.value.len], header.value);
        const value = head_out[head_len..][0..header.value.len];
        head_len += header.value.len;
        headers_out[header_count] = .{ .name = name, .value = value };
        header_count += 1;
    }

    if (view.body.len > body_out.len) return error.BufferOverflow;
    @memcpy(body_out[0..view.body.len], view.body);
    return .{
        .status = view.status,
        .headers = headers_out[0..header_count],
        .body = body_out[0..view.body.len],
    };
}

/// Validates field lines without interpreting framing semantics.
fn validate_field_lines(fields: []const u8) ?ParseFailure {
    var lines = std.mem.splitSequence(u8, fields, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .malformed;
        if (!valid_header_name(line[0..colon])) return .malformed;
        if (!simd.valid_http_field_value(std.mem.trim(u8, line[colon + 1 ..], " \t"))) {
            return .malformed;
        }
    }
    return null;
}

fn valid_header_name(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn is_hexadecimal(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn is_decimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}
