# HTTP/1.1 Client

µWebZockets ships a bounded HTTP/1.1 client built on the same libxev event loop
as the server. It performs one request per connection, buffers the response in
startup-allocated storage, and adds no allocation to the plaintext request
path. A TLS fetch allocates its BoringSSL session and memory BIO once per
connection, exactly like the server's `init_tls`; nothing in the read, parse,
or write paths allocates. This document covers the client surface;
[architecture.md](architecture.md) covers the shared event loop and
[memory_model.md](memory_model.md) covers the server slab the same design rules
come from.

HTTP/2 and HTTP/3 clients are deliberately not provided. The client speaks
HTTP/1.1, advertises `http/1.1` through ALPN, and closes each connection after
one exchange.

## Getting started

`fetch_blocking` runs one request to completion on a temporary single-slot
client. It is the simplest entry point and what tests use:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

pub fn main(init: std.process.Init) !void {
    var storage: uz.client.FetchStorage = .{};

    const outcome = try uz.client.fetch_blocking(init.io, .{
        .method = .get,
        .host = "127.0.0.1",
        .path = "/status",
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
    }, .{
        .port = 8080,
        .connect_timeout_ms = 2_000,
        .read_timeout_ms = 5_000,
    }, &storage);

    switch (outcome) {
        .response => |response| std.log.info("status {d}, {d} bytes", .{
            response.status,
            response.body.len,
        }),
        .failure => |failure| std.log.err("fetch failed ({s}): {s}", .{
            @tagName(failure.kind),
            failure.message,
        }),
    }
}
```

The returned view borrows `storage`: header names, header values, and the body
stay valid as long as `storage` does.

## The callback client

`client(max_inflight)` returns a type that owns one event loop and a fixed
array of `max_inflight` request slots:

```zig
const MyClient = uz.client.client(16);

var fetcher = try MyClient.init(init.io);
defer fetcher.deinit();

const FetchContext = struct {
    completed: bool = false,

    fn on_outcome(context: *anyopaque, outcome: uz.client.FetchOutcome) void {
        const self: *FetchContext = @ptrCast(@alignCast(context));
        _ = outcome;
        self.completed = true;
    }
};

var context = FetchContext{};
try fetcher.fetch(.{
    .method = .post,
    .host = "127.0.0.1",
    .path = "/submit",
    .body = "name=value",
}, .{ .port = 8080 }, &context, FetchContext.on_outcome);

try fetcher.run();
```

`fetch` only arms work; nothing runs until `run` drives the loop. `run` returns
when every in-flight request has completed. A callback that calls `fetch` for
another request keeps `run` alive until that request finishes too. Slots are
handed out from a free list, so a burst larger than `max_inflight` fails fast
with `error.InflightCapacityReached` instead of growing memory.

## API reference

| Name | Description |
| --- | --- |
| `Method` | `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `query`. `query` serializes as `QUERY`. |
| `Header` | Borrowed `name` and `value` slices. |
| `Request` | `method`, `host`, `path`, `headers`, `body`. Slices are borrowed. |
| `TlsOptions` | `verify`, `ca_path`, `server_name`. |
| `FetchOptions` | `port`, `tls`, `connect_timeout_ms`, `read_timeout_ms`, `response_body_capacity`. |
| `ResponseView` | `status`, `headers`, `body`. Borrowed for one callback or one `FetchStorage`. |
| `FailureKind` | `connect`, `tls`, `protocol`, `timeout`, `closed`, `capacity`. |
| `Failure` | `kind` plus a static, process-lifetime `message`. |
| `FetchOutcome` | `response: ResponseView` or `failure: Failure`. |
| `FetchCallback` | `fn (context: *anyopaque, outcome: FetchOutcome) void`. |
| `client(max_inflight)` | Client type with `init`, `deinit`, `fetch`, `run`. |
| `FetchStorage` | Caller-owned storage for `fetch_blocking` views. |
| `fetch_blocking` | Runs one request on a temporary client and copies the response into `FetchStorage`. |

The request builder always emits `Host`, a `Content-Length` when a body is
present, and `Connection: close`. A caller header named `Host`,
`Content-Length`, `Transfer-Encoding`, or `Expect` is rejected with
`error.ReservedHeader` rather than producing a duplicate field.

Responses support `Content-Length`, `chunked` transfer coding with trailers, and
close-delimited bodies. `HEAD` replies and `204`, `205`, and `304` statuses
complete with an empty body regardless of framing fields. Up to eight
unsolicited `100 Continue` responses are skipped; any other 1xx status is a
protocol failure. Bodies are decoded in place into the slot's response buffer.

## Capacity and ownership

| Bound | Value |
| --- | ---: |
| In-flight requests | `max_inflight`, compile-time |
| Response head including status line | 16 KiB |
| Response header fields | 64 |
| Response trailers | 8 KiB |
| Decoded response body | `FetchOptions.response_body_capacity`, at most 64 KiB |
| Generated request head | 8 KiB |
| Request body | borrowed from the caller, unbounded except by the transport |
| Socket read chunk | 8 KiB |
| TLS ciphertext staging | 8 KiB per socket write, 32 KiB per BIO pair side |

- The client value embeds every slot, buffer, completion, and timer. Keep it at
  a stable address: do not copy it after `init`.
- One client belongs to one thread and one event loop. `fetch` and `run` are
  event-loop confined; cross-thread completion is not supported.
- `Request` slices and `TlsOptions.server_name` stay borrowed until the
  callback runs. `FetchOptions` and `TlsOptions` are copied by value.
- A `ResponseView` is valid for the duration of the callback. After the
  callback returns, the slot can be reused. `fetch_blocking` extends that
  lifetime to the lifetime of the `FetchStorage` it was given.
- Callbacks run before the slot returns to the free list, so a callback that
  starts a follow-up fetch needs `max_inflight` to cover both requests.
- `deinit` asserts that no request is in flight and that every slot is idle.
  Drive `run` until it returns before calling `deinit`.

## Timeouts

`connect_timeout_ms` bounds the TCP connect. `read_timeout_ms` bounds
everything after the connect completes: the TLS handshake, the request write,
and the response read. Deadlines use the monotonic clock and a libxev timer
with millisecond granularity; a timer never fires before its deadline. A value
of zero expires as soon as the phase starts, so both timeouts should be
non-zero in practice. The loop wakes at least once per `read_timeout_ms` while
a fetch is pending so a deadline change is observed promptly.

## Failures and error semantics

`fetch` returns errors only before or during request setup, when nothing is
armed: capacity exhaustion, invalid request fields, invalid host addresses, and
TLS context or session creation failures. Those are programming or
configuration mistakes and surface as Zig errors.

Everything after I/O starts becomes a `FetchOutcome.failure` delivered to the
callback: connect errors (`.connect`), handshake and record errors (`.tls`),
malformed or conflicting responses (`.protocol`), expired deadlines
(`.timeout`), peer closes and socket failures (`.closed`), and bounded storage
exhaustion (`.capacity`). Should an early error still reach `fetch_blocking`,
it is mapped to the corresponding failure kind. Failure messages are static
strings and stay valid after the callback returns.

A connection is always closed during teardown. Every cancel completion and the
socket close drain before the callback runs, so a slot cannot observe a stale
completion or be reused early. There are no redirects, cookies, proxies, or
retries; the caller decides what to do with a failure.

## TLS trust rules

BoringSSL ships no default trust store, so verification fails closed:

- `verify = true` with `ca_path = null` returns `error.CaPathRequired` from
  `fetch` and a `.tls` failure from `fetch_blocking`.
- `verify = true` loads `ca_path` (a PEM bundle) into the context with
  `SSL_CTX_load_verify_locations` and requires the leaf chain to terminate in
  that trust store.
- `server_name` is sent through SNI and, when verifying, checked against the
  certificate: DNS names use the DNS SANs with the deprecated common-name
  fallback disabled, and IPv4 or IPv6 literals use the IP SANs.
- `verify = false` disables chain and name checks and is a development-only
  mode. It exists for talking to the ephemeral development certificates in
  [tls.md](tls.md); never ship it.
- The TLS context pins TLS 1.3 as both the minimum and maximum protocol
  version. A peer that cannot negotiate TLS 1.3 fails the handshake with a
  `.tls` failure instead of falling back to an older protocol.

One client caches at most one TLS context. Changing `verify` or `ca_path`
between fetches on the same client fails with `error.TlsConfigurationMismatch`
so a verification result is never reused under different trust rules. The
context is created on the first TLS fetch and released in `deinit`. Creating
it reads and parses the CA bundle synchronously inside `fetch`, so arm the
first TLS fetch between `run` calls rather than from a completion callback;
later TLS fetches reuse the context.

The client does not present a certificate and has no mutual-TLS configuration.

## Addresses

`Request.host` must be a numeric IPv4 or IPv6 literal; DNS resolution is not
provided, so `fetch` returns `error.InvalidHostAddress` for a hostname. Use a
literal address and put the name in `TlsOptions.server_name` for SNI and
verification. IPv6 literals are written without brackets (`::1`); the request
builder adds brackets to the `Host` header.

## Related reading

- [tls.md](tls.md) for the server credential model and ephemeral certificates.
- [architecture.md](architecture.md) for the libxev loop and completion
  lifecycle the client shares with the server.
- [memory_model.md](memory_model.md) for the fixed-capacity slab rules the
  client follows.

## Verification

The client suite covers the pure response parser (framing, trailers, 1xx,
malformed input), request-builder validation, TLS trust failures, slot reuse
after a failed fetch, and loopback end-to-end fetches over plaintext and TLS.
The loopback tests spawn a peer thread and run in every sanitizer graph; ASan
runs set `use_sigaltstack=0` because Zig's thread-local alternate signal stack
is not page aligned for ASan's thread teardown.
