# Application API Guide

This is the practical guide to the µWebZockets application surface. It is the
map; each linked protocol document has the wire-level detail.

- [http.md](http.md) — HTTP/1.1 parsing, routing, middleware, helpers, static files
- [http2.md](http2.md) — HTTP/2, HPACK, RFC 8441 tunnels
- [quic.md](quic.md) — HTTP/3, QPACK, WebTransport status
- [websocket.md](websocket.md) — RFC 6455, compression, pub/sub
- [json_rpc.md](json_rpc.md) — JSON-RPC 2.0
- [client.md](client.md) — outbound HTTP/1.1 client
- [memory_model.md](memory_model.md) — capacities, slab layout, backpressure
- [deployment.md](deployment.md) — production checklist

## Application types

| Type | Connections | Message size | Write queue | Idle timeout |
| --- | ---: | ---: | ---: | ---: |
| `App(N)` | `N` | 16 KiB | 64 KiB | 120 s |
| `ConfiguredApp(N, message, queue)` | `N` | compile-time | compile-time | 120 s |
| `ConfiguredAppWithTimeout(N, message, queue, timeout_ms)` | `N` | compile-time | compile-time | compile-time |
| `Server.builder(io)` | runtime config | runtime config | runtime config | runtime config |

`App(N)` is the shortest path. `Server.builder` is the fluent path for runtime
configuration and presets:

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();
```

`build` performs exactly one application allocation: the contiguous slab behind
the pool, request buffers, message regions, write queues, router storage, and
optional compression scratch. `ServerConfig` presets are listed in
[memory_model.md](memory_model.md).

## Lifecycle

```zig
var app = try uz.App(128).init(init.io);   // one allocation
defer app.deinit();                        // drains, then releases the slab

_ = try app.get("/", hello);
try app.listen_all(&.{                    // bind every port before accepting
    .{ .address = "0.0.0.0", .port = 3000 },
    .{ .address = "0.0.0.0", .port = 3001 },
});
try app.run();                             // blocks until shutdown drains
```

`listen` is the one-endpoint convenience wrapper. `listen_all` replaces it; it
returns `error.AlreadyListening` after either call. A `.tls = true` endpoint
requires an HTTPS initializer (`init_https`, `init_https_ephemeral`, or
`init_http3`) before the listen call.

| Step | Rules |
| --- | --- |
| `init*` | Choose plaintext, HTTPS, mTLS, or HTTP/3; HTTPS variants load credentials before the loop starts |
| Route registration | Before the first `listen`; later calls return `error.RoutesLocked` |
| `listen` / `listen_udp` | Bind and start accepting; the `App` must stay at a stable address |
| `listen_all` | Bind up to four TCP endpoints, verify every port, then arm accepts |
| `run` | Drives the loop until shutdown completes; `error.ApplicationAlreadyRunning` if re-entered |
| `request_shutdown` | Safe from any thread or a callback; stores the request and wakes the owning loop, then returns |
| `shutdown` | Loop-thread only: from a callback it begins shutdown, otherwise it drives the loop and drains before returning |
| `deinit` | Panics if called from inside the event loop; always pair with `defer` |

### Graceful shutdown signals

```zig
try app.catch_shutdown_signals();
try app.run();
```

`catch_shutdown_signals` installs a process-wide SIGINT/SIGTERM watcher (a
Windows console-control handler on Windows) that requests the same shutdown
path as `shutdown`. Install it once per process. Cluster applications use
`Cluster.catch_shutdown_signals()`, which requests shutdown for every worker.
The watcher is allocation-free and coalesces repeated signals.

## Routing and handlers

```zig
_ = try app.get("/users/:id", show_user);
_ = try app.post("/users", create_user);
_ = try app.query("/search", search);        // RFC 10008 QUERY
_ = try app.trace("/probe", trace);           // opt-in TRACE
_ = try app.any("/health", health);
```

| Registration | Callback signature | Use |
| --- | --- | --- |
| `get` / `head` / `post` / `put` / `delete` / `patch` / `options` / `trace` / `query` / `any` | `fn (*Request, *Response) void` | Synchronous work |
| `route_context` / `get_context` | `fn (*anyopaque, *Request, *Response) void` | Explicit caller-owned state |
| `route_async` / `get_async` | `fn (*Request, AsyncResponse) void` | Work completed later |
| `route_async_context` / `get_async_context` | `fn (*anyopaque, *Request, AsyncResponse) void` | Deferred work with state |

Path patterns: exact segments stay on the radix fast path, `:name` captures one
nonempty segment, and a terminal `*name` captures the remainder. Static routes
win. Malformed patterns fail registration rather than matching ambiguously.

`trace` is opt-in: the library does not register a route or synthesize the
RFC 9110 echo response. A handler that reflects the request must redact
`Authorization`, `Cookie`, `Proxy-Authorization`, and application secrets, and
must keep the reflected bytes within the response capacity. Prefer disabling
TRACE on public deployments unless an operational requirement exists.

## Middleware

`App.use(context, handler)` appends at most 32 global middleware callbacks; they
run in registration order and stop on `.stop` or a started response. Built-in
middleware: `Cors`, `SecurityHeaders`, `Auth`, and `RateLimit`. See
[http.md](http.md#middleware).

## Request

| Group | API |
| --- | --- |
| Target | `req.method`, `req.target`, `req.path`, `req.query`, `req.url()` |
| Headers | `req.headers()`, `req.get_header`, `req.get_unique_header`, `req.header_has_token` |
| Body | `req.text()`, `req.bytes()`, `req.json(T, allocator)`, `req.body` |
| Route captures | `req.get_param`, up to 16 borrowed captures |
| Query and form | `req.query_params()`, `req.query_params_of(N)`, `req.form()` |
| Ownership | `req.clone(allocator)` returns an `OwnedRequest` for deferred work |

## Response

| Group | API |
| --- | --- |
| Simple bodies | `res.text`, `res.html`, `res.bytes`, `res.json`, `res.json_buf` |
| Streaming JSON | `res.begin_json()` |
| Chunked output | `begin_chunked`, `write_chunk`, `end_chunks` |
| Drain-driven bodies | `res.begin_stream()` with a `StreamProducer` |
| Files | `res.send_file()`, `App.static` |
| Server-Sent Events | `res.sse()` |
| Redirects and headers | `res.redirect`, `res.append_header`, `end_with_headers` |

## Asynchronous responses

An async token is copyable, generation-checked, and completes exactly once:

```zig
fn deferred(_: *uz.Request, token: uz.AsyncResponse) void {
    // Hand the token to a worker or timer, then complete it on this loop.
    token.complete("200 OK", "later") catch {};
}
```

A pending token keeps the request buffer or HTTP/3 stream from being reused.
Complete it on the owning event loop; marshal cross-thread results back to that
loop before completing.

## WebSocket, static files, RPC, OpenAPI

```zig
_ = try app.ws("/chat", .{ .open = on_open, .message = on_message, .close = on_close });
_ = try app.static("/assets", "public", .{});
_ = try app.rpc("/rpc", &service);
_ = try app.openapi("/openapi.json");
```

## Cluster

`listen_all(&.{ ... })` binds up to four TCP endpoints and does not arm any
accept completion until every socket has bound and reported a local port. A
bind or verification failure closes the sockets created by that call, leaves
`listener_count == 0`, and keeps routes unlocked. Each endpoint may set
`.tls = true` or `.tls = false`; null follows whether the application owns a TLS
context. All TLS listeners share the application certificate.

`App.cluster(worker_count)` and
`Server.builder(...).build_cluster(allocator, worker_count, options)` return a
heap-backed thread-per-core manager. `worker_count` is the compiled capacity.
`build_cluster` keeps that exact count; `build_cluster_from_environment`
resolves `UWEBZOCKETS_WORKERS`, or the platform CPU count, and
`ClusterOptions.worker_count` selects a smaller active count explicitly.
Configure routes per worker, `listen` once, and `run` joins every worker.
`Cluster.publish` broadcasts through bounded per-worker rings, and
`Cluster.request_shutdown` drains all workers.
Because it returns `void`, `request_shutdown` after `deinit` is a documented
non-erroring no-op: the worker slice has already been released, so rebuild the
cluster instead of relying on shutdown to report a lifecycle error. The guard
is explicit in `Cluster.request_shutdown` as of 1.9.0; a public lifecycle
getter would require an ADR. See [architecture.md](architecture.md) and
[ADR 0003](adr/0003-tls-cluster-operational-boundaries.md).

### TLS-enabled clusters

```zig
Cluster.enable_https(cert_path: [:0]const u8, key_path: [:0]const u8) !void
Cluster.enable_https_ephemeral() !void
```

Call one of these exactly once after `configure` and before `listen`:

```text
build_cluster -> configure -> enable_https (or enable_https_ephemeral)
              -> listen -> run -> request_shutdown or shutdown signal -> deinit
```

Each worker creates and owns one BoringSSL `SSL_CTX` before any listener
exists; each connection creates its own `SSL` from that worker's context.
Credential files are read once per worker at startup. TLS state is never
shared between loops, and the request path adds no lock or allocation. The
context is TLS 1.3 only with ALPN `h2` then `http/1.1`. `enable_https` does not
configure client certificates.

HTTP/3/QUIC clustering is not supported. `init_http3` and `listen_udp` remain
single-application APIs, and a cluster listener is TCP/TLS only.

| Error | Cause |
| --- | --- |
| `error.ClusterDeinitialized` | An enable call or `listen` was made after `deinit` |
| `error.ClusterRunning` | `enable_https` was called while `run` was active |
| `error.AlreadyListening` | `enable_https` was called after `listen` started |
| `error.TlsAlreadyEnabled` | `enable_https` was called more than once |
| `error.CertificateLoadFailed` / `error.PrivateKeyLoadFailed` | The PEM files could not be read or parsed; a mismatched key fails here too |
| `error.TlsContextCreationFailed` / `error.ProtocolConfigurationFailed` | BoringSSL could not create or configure the context |
| `error.ApplicationUnavailable` | A worker was already shutting down or deinitialized |

A failed enable releases only the contexts it created and can be retried. Use
`enable_https` with PEM files in production; `enable_https_ephemeral` generates
a distinct development certificate per worker and can also return the
`Ephemeral*` generation errors in [tls.md](tls.md#zig-error-reference). See
[tls.md](tls.md#tls-enabled-clusters).

## Observability

```zig
var server = try uz.Server.builder(init.io)
    .with_observability(true)
    .with_dev_log(true)
    .build(std.heap.page_allocator);
```

- `with_dev_log(true)` prints a startup wordmark and per-request lines; stderr
  is only written when it is a terminal unless `set_dev_log_file` binds a file.
- `App.log_metrics()` records every counter of the bounded Prometheus registry.
- `uwz_connections_accepted`, `uwz_connections_closed`, `uwz_http_requests`,
  and `uwz_ws_messages` advance for HTTP/1.1 and HTTP/2. HTTP/3 emits request
  records but does not advance the counter registry yet.

## Ownership and lifetime rules

| Value | Valid until |
| --- | --- |
| `Request` fields, route captures | Synchronous handler return, or async token completion |
| WebSocket `message` slice | Callback return |
| `ResponseView` from the client | Callback return, or `FetchStorage` lifetime |
| `AsyncResponse` token | Completed exactly once; copyable |
| `App` value | Must not move after `listen`/`listen_udp`, nor after any context-capturing registration: `openapi`, `datagram`, or the observability install performed by `listen` |

Slices always borrow connection storage. Copy into bounded application storage
or use `clone` for work that outlives the callback.

## Error handling

Framework methods return Zig error sets; route handlers report failures through
the `Response`. Capacity exhaustion is explicit: `413` for oversized bodies,
`431` for oversized headers, `503` for exhausted WebSocket tunnel or capacity
limits, and `error.WouldBlock` from WebSocket `send`. Structured JSON rejection
bodies name the limit and its value. See
[troubleshooting.md](troubleshooting.md).

## C and C++ consumers

`zig build lib` installs `zig-out/include/uWebZockets.h` with versioned opaque
handles, `uwz_slice` views, and a versioned error mapping. The C ABI is a
high-level server ABI: the low-level `udp`, HTTP/2, HPACK, HTTP/3-extension,
WebTransport, and client modules are Zig-only. See
[operations.md](operations.md#c-abi).
