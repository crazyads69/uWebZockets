//! Pure HTTP/1.1 request head builder.
//!
//! The builder never performs I/O or allocation; it formats into caller-owned
//! storage and fails closed on malformed or reserved fields.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("types.zig");

const Method = types.Method;
const Header = types.Header;
const Request = types.Request;

/// Framing inputs that do not come from the request itself.
pub const HeadOptions = struct {
    port: u16,
    tls: bool,
    /// Sends `Connection: close` so one socket carries exactly one request.
    connection_close: bool = true,
};

/// Failure modes of the request head builder.
pub const HeadError = error{
    InvalidPath,
    InvalidHost,
    InvalidHeaderName,
    InvalidHeaderValue,
    ReservedHeader,
    HeadTooLarge,
};

/// Returns the wire name for a method selector.
pub fn method_name(method: Method) []const u8 {
    return switch (method) {
        .get => "GET",
        .head => "HEAD",
        .post => "POST",
        .put => "PUT",
        .patch => "PATCH",
        .delete => "DELETE",
        .options => "OPTIONS",
        .query => "QUERY",
        .trace => "TRACE",
    };
}

/// Serializes a request head into `out` and returns the written slice.
///
/// Always emits `Host` and, unless disabled, `Connection: close`. A
/// caller-supplied header with a name this builder emits is rejected instead
/// of producing a duplicate field.
pub fn write_head(request: Request, options: HeadOptions, out: []u8) HeadError![]const u8 {
    if (!valid_path(request.path)) return error.InvalidPath;
    if (!valid_host(request.host)) return error.InvalidHost;

    var writer = std.Io.Writer.fixed(out);

    writer.writeAll(method_name(request.method)) catch return error.HeadTooLarge;
    writer.writeAll(" ") catch return error.HeadTooLarge;
    writer.writeAll(request.path) catch return error.HeadTooLarge;
    writer.writeAll(" HTTP/1.1\r\nHost: ") catch return error.HeadTooLarge;
    write_host(&writer, request.host, options.port, options.tls) catch return error.HeadTooLarge;
    writer.writeAll("\r\n") catch return error.HeadTooLarge;

    if (request.body.len > 0) {
        writer.print("Content-Length: {d}\r\n", .{request.body.len}) catch return error.HeadTooLarge;
    }
    if (options.connection_close) {
        writer.writeAll("Connection: close\r\n") catch return error.HeadTooLarge;
    }

    for (request.headers) |header| {
        if (!valid_header_name(header.name)) return error.InvalidHeaderName;
        if (!simd.valid_http_field_value(header.value)) return error.InvalidHeaderValue;
        if (is_reserved_header(header.name)) return error.ReservedHeader;

        writer.writeAll(header.name) catch return error.HeadTooLarge;
        writer.writeAll(": ") catch return error.HeadTooLarge;
        writer.writeAll(header.value) catch return error.HeadTooLarge;
        writer.writeAll("\r\n") catch return error.HeadTooLarge;
    }
    writer.writeAll("\r\n") catch return error.HeadTooLarge;
    return writer.buffered();
}

/// Appends the authority form of `host`, bracketing IPv6 literals and
/// omitting the default port.
fn write_host(
    writer: *std.Io.Writer,
    host: []const u8,
    port: u16,
    tls: bool,
) !void {
    if (std.mem.indexOfScalar(u8, host, ':') != null and host[0] != '[') {
        try writer.writeByte('[');
        try writer.writeAll(host);
        try writer.writeByte(']');
    } else {
        try writer.writeAll(host);
    }

    const default_port: u16 = if (tls) 443 else 80;
    if (port != default_port) try writer.print(":{d}", .{port});
}

/// Validates an origin-form request target.
pub fn valid_path(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '#') return false;
    }
    return true;
}

/// Validates a numeric host or bracketed address used in the authority.
pub fn valid_host(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '/') return false;
    }
    return true;
}

/// Validates an HTTP field name (RFC 9110 token).
pub fn valid_header_name(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!is_tchar(byte)) return false;
    }
    return true;
}

/// Reports whether the builder emits this header itself.
pub fn is_reserved_header(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Host") or
        std.ascii.eqlIgnoreCase(name, "Content-Length") or
        std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
        std.ascii.eqlIgnoreCase(name, "Expect");
}

fn is_tchar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
