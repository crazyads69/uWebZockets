# Memory Model

µWebZockets never allocates on the request path. Every connection slot, request
buffer, message region, response queue, and protocol table is sized before the
first listener starts and then reused for the process lifetime. This document
describes the layout, the startup slab, and the capacity contract.

## Allocation rules

| Phase | Allocation |
| --- | --- |
| `build` / `init` | One contiguous application slab via the caller allocator |
| Route registration | Fixed router storage only; lazily allocated RFC 7692 scratch is freed in `deinit` |
| `init_tls` | BoringSSL-internal state, bounded per connection |
| `init_https_ephemeral` / `init_http3_ephemeral` | One-time P-256 key and certificate generation; every generated object is released before startup |
| `Cluster.enable_https` / `enable_https_ephemeral` | One BoringSSL `SSL_CTX` per worker plus startup credential loading or generation, allocated once outside the application slab; each connection creates its own `SSL` from that context |
| `listen_udp` | QUIC engine pools created before the listener succeeds |
| Request path | None |
| `deinit` | Every slab released once through its owner |

Cluster TLS does not change the startup slab or `slab_bytes()`: the per-worker
`SSL_CTX` objects are created at enable time, before listening, and live in
BoringSSL-owned memory. Each connection's `SSL` remains per-connection state,
and the request path stays allocation-free.

`Request.clone(allocator)` and `req.json(T, allocator)` are the only explicitly
allocating public request APIs. Everything else returns `error.WouldBlock` or a
specific bounded error instead of growing memory. Query and form parsing
(`Request.query_params`, `Request.form`), percent decoding, error documents,
`Accept` scoring, ETag matching, and the cookie helpers all slice or format into
caller-owned storage and never allocate. `Response.begin_json` streams JSON
through a fixed stack buffer into chunked response parts, so body size is
bounded by the configured write queue rather than by a rendering buffer.

## The startup slab

`src/router/config.zig` turns one `ServerConfig` into one `SlabLayout`. The
layout is computed with checked arithmetic and partitions a single aligned block
into these regions, in order:

| Region | Size |
| --- | --- |
| Connection pool storage | `max_connections * sizeof(TcpConnection)` |
| Pool freelist indices | `max_connections * sizeof(usize)` |
| HTTP/1.1 request buffers | `max_connections * request_stride` |
| Header extras beyond the inline 64 | `max_connections * (max_header_count - 64) * 2 slices` when configured |
| Route-param extras beyond the inline 16 | `max_connections * (max_route_params - 16) * 2 slices` when configured |
| HTTP/2 session storage | `max_connections * h2_session_stride` |
| Response write queues | `max_connections * write_queue_size` |
| WebSocket message storage | `max_connections * max_ws_message_size` |
| RFC 7692 compression scratch | `max_connections * 2 * worst_case_scratch` when enabled |
| HTTP gzip pool | One codec plus `max_body_size`-bounded output scratch per active worker when `http_compression = true` |
| Router storage (nodes, patterns, middleware, registry) | appended after the per-connection regions |

`request_stride` is the request line, header block, framing slack, and
`max_body_size`, rounded to a 16-byte boundary. Write queues start on a cache
line. `required_bytes` and `carve` share one offset computation, so sizing and
partitioning cannot drift apart. Pool storage is zeroed during initialization;
every other region is written before it is read.

`App.init` and `App.init_configured` allocate this block once and free it once;
`App.init_from_slab` accepts caller-owned storage with the same contract. Each
worker in a cluster owns its own slab and, when TLS is enabled, its own
`SSL_CTX`; no slab region or mutable TLS state is shared between threads.

## Capacity presets and the builder

`ServerConfig`, `Presets`, and `Server.builder` replace byte arithmetic with
named limits:

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();
```

| Preset | Connections | WebSocket message | Write queue | Request body |
| --- | ---: | ---: | ---: | ---: |
| `Presets.microservice` | 256 | 8 KiB | 16 KiB | 64 KiB |
| `Presets.websocket_chat` | 512 | 32 KiB | 32 KiB | 4 KiB |
| `Presets.file_server` | 128 | 4 KiB | 512 KiB | 8 KiB |

Capacities stay compile-time because they size the generated application type;
pass literals or `const` values. `ServerConfig.slab_bytes()` and
`Server.builder(...).slab_bytes()` report the exact footprint before allocation. The libxev
event loop allocates its fixed 4096-entry backend table during `build`,
independently of application capacity.

Each embedded HTTP/2 session (eight streams with request, body, and response
storage) dominates the per-connection footprint. Presets therefore spend bytes
on the capacity each workload actually exercises instead of maximizing every
dimension. `max_body_size` sizes the HTTP/1.1 request buffers; HTTP/2 stream
bodies and HTTP/3 request bodies stay bounded by their compiled 16 KiB
transport slabs.

## Structure of arrays

Large collections are stored as parallel arrays so hot scans touch only the
fields they need:

- **Connection pool** (`src/core/pool.zig`): one contiguous `TcpConnection`
  slab plus a freelist index stack and a `StaticBitSet` activity bitmap. Acquire
  and release are O(1) and range-checked; `from_slices` adopts caller-carved
  storage without owning it. Each slot embeds one idle `TimerNode` and nine
  parking slots (HTTP/1 plus one per HTTP/2 stream) so deadlines never
  allocate.
- **Router** (`src/router/radix.zig`): parallel arrays for node segments,
  child/sibling/parent links, route bits, method handlers, and WebSocket
  behaviors. An open-addressed FNV-1a index resolves exact static routes before
  the radix walk, verifying each hit against the node's stored segments so a
  hash collision cannot select the wrong route; parameterized and wildcard
  matches live in bounded side tables.
- **HTTP/2 session** (`src/http2/server.zig`): per-stream arrays for request
  metadata, body lengths, pending offsets, and flags, plus connection-wide
  HPACK dynamic-table and decoded-header storage.
- **Cluster inbox** (`src/router/cluster.zig`): topic, payload, length, and flag
  arrays with a sequence ring; only the sequence words are atomic, and the ring
  positions sit on separate cache lines.
- **JSON-RPC registry** (`src/rpc/json_rpc.zig`): procedure metadata in
  parallel arrays with an open-addressed index and contiguous copied method
  bytes.
- **Query and form pairs** (`src/http/query.zig`): key and value pointers plus
  their lengths live in four parallel fixed arrays (32 entries), so every slice
  stays borrowed from the request target and `Request.query_params()` performs
  no copy and no allocation.
- **Cookie pairs** (`src/http/cookie.zig`): name and value pointers plus their
  lengths live in four parallel fixed arrays (32 entries), populated by a
  vectorized `=`/`;` scan over the header; `CookieJar.parse` performs no copy
  and no allocation.

## Capacity and protocol limits

The defaults are deliberately finite:

| Resource | Limit |
| --- | ---: |
| Request line | 8 KiB default; `ServerConfig.max_request_line_size` |
| HTTP headers | 16 KiB total and 64 inline fields by default; `max_header_size` and `max_header_count` |
| Query and form pairs | 32 default; compile-time `query.QueryParamsOf` capacity |
| Cookie pairs | 32 default; compile-time `cookie.CookieJarOf` capacity |
| HTTP request body | 16 KiB default; `ServerConfig.max_body_size` |
| Routes | 256 radix nodes; `max_route_nodes` |
| Parameterized routes | `max_pattern_routes` patterns; `max_route_params` captures per request (16 inline) |
| Middleware | 32 callbacks; `max_middleware` |
| OpenAPI route registry | 320 entries, 64 KiB of paths |
| JSON-RPC procedures | 64 by default |
| JSON-RPC method names | 4 KiB copied storage by default |
| JSON-RPC response | 16 KiB by default |
| Mounted static directories | 8 |
| Static file body | configured write queue minus 4 KiB |
| Cluster message queue | 64 messages per worker |
| Route path | 2 KiB default; `max_route_path_size` |
| WebSocket message | 16 KiB with `App` |
| WebSocket control payload | 125 bytes |
| HTTP/3 decoded headers | `max_header_size` bytes (at most 65535 when HTTP/3 is enabled) and `max_header_count` fields (spill extras) |
| HTTP/3 request body | `max_h3_body_size` |
| HTTP/3 response metadata | `max_h3_response_header_size`, `max_h3_response_header_count` |
| HTTP/3 response body | configured write-queue capacity |
| QUIC UDP payload | 2 KiB |
| QUIC connections and active streams | configured connection capacity |
| HTTP/2 active streams | compile-time `max_http2_streams` (8) |
| HTTP/2 session storage | `h2_session_bytes()` per connection in the startup slab |
| HTTP/2 header block, bodies, response headers | `max_h2_header_block_size`, `max_h2_body_size`, `max_h2_response_header_size`, `max_h2_response_header_count` |
| HPACK table, fields, and decoded bytes | `Capacities`/`Storage` carved per session |
| C ABI | 1,024 connections, 64 copied route paths |
| Write queue | fixed per connection |
| Idle timeout | 120 seconds by default |

Oversized or ambiguous input is rejected rather than expanded dynamically.

## Backpressure

Response bytes enter a per-connection bounded ring. A fully drained ring
normalizes its head so the next logical write stays contiguous instead of
creating a delayed-ACK wrap split. Producers observe `error.WouldBlock`
instead of causing unbounded memory growth; WebSocket routes use the `drain`
callback and `buffered_amount` to resume producers. Chunk headers, bodies, and
terminators are copied into the same ring as parts, so chunked responses need no
per-connection scratch. HTTP/1.1 heads are scatter-written the same way, so a
response with thousands of header fields is bounded by the ring, not by a fixed
header-formatting buffer; `with_write_queue_size` sizes that ring per server.
`Response.begin_stream` bodies park on `error.WouldBlock` and are re-invoked
when the ring drains, so the queue bounds one step of a response, never its
total size.

## DX rejection documents

Oversized input returns structured JSON instead of a silently dropped
connection. The transport reads a fixed `RejectionPolicy` from the connection's
application, formats the document into a 384-byte stack buffer, and writes it
through the normal bounded response path:

```json
{"error":{"code":"payload_too_large","message":"Request body exceeded the 64KB limit. Consider increasing 'max_body_size' in ServerConfig.","limit_bytes":65536}}
```

Oversized headers return the equivalent `431` document. Neither path allocates,
and neither requires the handler to be involved.
