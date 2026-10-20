# Protocols

µWebZockets exposes one application boundary (`Request`, `Response`, the radix
router, and middleware) across every transport it serves. A handler written
once runs unchanged on HTTP/1.1, HTTP/2, and HTTP/3.

This page is the index. Each protocol has its own document with wire behavior,
ownership rules, capacity limits, and compliance status.

| Protocol | Document | Scope |
| --- | --- | --- |
| HTTP/1.1 | [http.md](http.md) | Request parsing, routing, middleware, helpers, static files |
| HTTP/2 | [http2.md](http2.md) | Frames, HPACK, flow control, RFC 8441 tunnels |
| HTTP/3 | [quic.md](quic.md) | QUIC, QPACK, WebTransport status, RFC 10008 `QUERY` |
| WebSocket | [websocket.md](websocket.md) | RFC 6455, RFC 7692 compression, pub/sub, heartbeats |
| JSON-RPC | [json_rpc.md](json_rpc.md) | JSON-RPC 2.0 services and typed procedures |
| HTTPS and TLS | [tls.md](tls.md) | Certificates, ALPN, 0-RTT policy, mTLS |
| HTTP client | [client.md](client.md) | Bounded outbound HTTP/1.1 over TCP and TLS |

Supporting documents: [architecture.md](architecture.md) for the runtime,
[memory_model.md](memory_model.md) for capacities and backpressure,
[callback_lifecycle.md](callback_lifecycle.md) for completion ordering, and
[operations.md](operations.md) for build, test, and release procedures.

## One boundary, every transport

The application surface is intentionally transport-neutral:

- `Request` carries the method, target, path, query, headers, body, and route
  captures. Slices borrow connection storage; copy them for deferred work with
  `Request.clone(allocator)`.
- `Response` carries `text`, `html`, `bytes`, `json`, `json_buf`, `redirect`,
  chunked output, streaming JSON, drain-driven producers, SSE, and file
  responses. Every helper writes into bounded storage.
- The router and middleware run before the handler, so authorization, rate
  limiting, CORS, and security headers apply identically on all transports.
- `App.route_async` and its context variants receive a generation-checked,
  one-shot response token that completes exactly once on the owning event loop.

## Web-standard API conventions

The public HTTP surface uses familiar WHATWG Fetch and Streams concepts where
they fit Zig, with allocation, ownership, and fallible I/O made explicit. It is
not a JavaScript API or a claim of full WHATWG conformance.

| Web concept | µWebZockets API | Storage model |
| --- | --- | --- |
| `Request.url` | `req.url()` | Borrowed request target |
| `Headers.get`, `has`, `entries` | `req.headers()` | Read-only view over bounded fields |
| Body `text`, bytes, JSON | `req.text()`, `req.bytes()`, `req.json(T, allocator)` | Borrowed bytes; explicit allocator for parsed JSON |
| Text, HTML, bytes, JSON responses | `res.text()`, `res.html()`, `res.bytes()`, `res.json()`, `res.json_buf()` | Direct bounded write or explicit temporary allocator |
| `Response.redirect` | `res.redirect(location, code)` | Validated `Location`; CR/LF rejected |
| Readable and writable byte streams | `uz.streams.ReadableByteStream`, `res.writable_stream()` | BYOB reads and transport-aware bounded writes |
| `pipeTo` | `uz.streams.pipe_to()` | Caller-owned transfer buffer and deterministic close |

Lower-level methods such as `end_with_headers`, `begin_chunked`, and
`write_chunk` remain available for precise protocol control.

## Compliance summary

| Area | Coverage |
| --- | --- |
| WebSocket | RFC 6455 and RFC 7692 per-message deflate; 517/517 Autobahn server cases accepted (514 `OK`, 3 `INFORMATIONAL`), including compression groups 12 and 13 |
| HTTP/1.1 | h1spec suite plus deterministic adversarial cases in the unit suite |
| HTTP/2 | Bounded RFC 9113 routing; one RFC 8441 WebSocket tunnel per connection |
| HTTP/3 | Bounded RFC 9114 request/response routing verified against curl/ngtcp2 and aioquic; extended CONNECT, WebTransport, push, and application datagrams remain helper-only |
| HTTP extensions | RFC 10008 `QUERY` routing with syntactic content-type checks; opt-in `TRACE` routing across HTTP/1.1, HTTP/2, HTTP/3, and the client |

See [operations.md](operations.md) for the full verification matrix and
[roadmap.md](roadmap.md) for the boundaries that are deliberate rather than
pending.
