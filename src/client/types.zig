//! Shared client request, response, and failure types.
//!
//! Every value here is plain data. Slices are borrowed from the caller for the
//! duration of one fetch, except where documented otherwise.

/// HTTP method selector accepted by the client request builder.
pub const Method = enum {
    get,
    head,
    post,
    put,
    patch,
    delete,
    options,
    query,
    trace,
};

/// One borrowed request or response header field.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Borrowed request description.
///
/// `host` is the numeric address used for the TCP connection and, by default,
/// the `Host` header value. Slices must stay valid until the fetch callback
/// runs.
pub const Request = struct {
    method: Method = .get,
    host: []const u8,
    path: []const u8 = "/",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// TLS trust and server-name policy for one fetch.
pub const TlsOptions = struct {
    /// Verifies the server chain and hostname. Requires `ca_path`.
    verify: bool = true,
    /// PEM bundle loaded into the BoringSSL trust store. BoringSSL ships no
    /// default store, so verification without this path fails closed.
    ca_path: ?[:0]const u8 = null,
    /// SNI and certificate hostname checked during verification.
    server_name: []const u8,
};

/// Timeouts and bounded response capacity for one fetch.
pub const FetchOptions = struct {
    port: u16,
    tls: ?TlsOptions = null,
    /// Deadline for the TCP connect alone.
    connect_timeout_ms: u32 = 5_000,
    /// Deadline covering the TLS handshake, request send, and response read.
    read_timeout_ms: u32 = 10_000,
    /// Upper bound on the decoded response body for this fetch.
    response_body_capacity: usize = default_response_body_capacity,
};

/// Borrowed view of a completed response.
///
/// Header and body slices point into client-owned storage. They are valid for
/// the duration of the callback invocation and must not be retained.
pub const ResponseView = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
};

/// Failure category reported through `FetchOutcome.failure`.
pub const FailureKind = enum {
    connect,
    tls,
    protocol,
    timeout,
    closed,
    capacity,
};

/// Terminal failure with a static explanatory message.
pub const Failure = struct {
    kind: FailureKind,
    message: []const u8,
};

/// Result of one fetch attempt.
pub const FetchOutcome = union(enum) {
    response: ResponseView,
    failure: Failure,
};

/// Receives exactly one fetch outcome on the client's event loop.
pub const FetchCallback = *const fn (context: *anyopaque, outcome: FetchOutcome) void;

/// Maximum accepted response head, including the status line.
pub const max_response_head_bytes = 16 * 1024;
/// Maximum accepted response header fields.
pub const max_response_header_fields = 64;
/// Default decoded response body bound.
pub const default_response_body_capacity = 64 * 1024;
/// Maximum generated request head.
pub const max_request_head_bytes = 8 * 1024;
/// Slack reserved for chunk framing and trailers beyond the decoded body.
pub const response_framing_slack = 4 * 1024;
