<p align="center">
  <img src="misc/uwebzockets_banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

A zero-allocation, shared-nothing server framework for Zig 0.16.0. One type-safe
`Request`/`Response` API serves HTTP/1.1, HTTP/2, HTTP/3, WebSocket, and
JSON-RPC from bounded slabs that are allocated once at startup, owned by one
thread each, and reused without locking.

- **Zero allocation:** no request, parse, route, or write path allocates.
- **Shared-nothing:** every worker runs its own libxev loop, slab set, and
  pinned physical core, coordinated only through lock-free rings.
- **Data-oriented:** struct-of-arrays pools, parallel router arrays, and
  compile-time capacities that make exhaustion explicit.
- **Readable types:** named callback, event, and override types instead of
  inline anonymous structs, reflection-driven shapes, or type gymnastics.
- **Cross-platform:** Linux and macOS (x86_64 and aarch64) are supported and
  tested. Windows (`x86_64-windows-gnu`) has a native compile and runtime job;
  official support is claimed only after that job is green for the release
  commit.

[Getting started](docs/getting_started.md) | [API guide](docs/api.md) |
[TLS](docs/tls.md) | [Architecture](docs/architecture.md) |
[Memory model](docs/memory_model.md) | [Protocols](docs/protocols.md) |
[Client](docs/client.md) | [Deployment](docs/deployment.md) |
[Operations](docs/operations.md) | [Roadmap](docs/roadmap.md)

## Quick start

With Nix installed, the shortest path to a running server is:

```sh
git clone https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
zig build hello_world -Doptimize=ReleaseSafe
```

In another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The `hello_world` build step compiles and starts the example on port 3000.
The first build downloads the pinned dependency packages through Zig's
package manager and caches them; later builds reuse the caches. The
`vendor/h1spec` submodule is only needed for the h1spec compliance suite.

### Use it in your own project

µWebZockets is a Zig package. Fetch a released tag (or a full commit) and
import the module; nothing else needs to be installed, and the package
manifest pulls BoringSSL, lsquic, and the other pinned dependencies itself.
Releases are source tags: no per-platform binary archives are published, so
`zig fetch` resolves the sources and the local toolchain builds them.

```sh
zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag-or-commit>'
```

Wire the dependency in `build.zig`:

```zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("uWebZockets", uz.module("uWebZockets"));
```

Then a complete server is a few lines:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a dependency") catch {};
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello);
    try app.listen("0.0.0.0", 3000);
    try app.run();
}
```

`zig build run` starts it and `curl http://127.0.0.1:3000/` prints the body.
The same module carries the rest of the battery: `app.ws(...)` for WebSocket,
`app.rpc(...)` for JSON-RPC, `app.static(...)` for assets,
`build_cluster` for thread-per-core workers, `init_https_ephemeral` for HTTPS
with no certificate files, `listen_all` for a deterministic multi-port startup
barrier, and `listen_udp` plus `init_http3` for HTTP/3.
`zig build lib` also installs
`zig-out/include/uWebZockets.h` for C and C++ consumers.

Pin a tag or full commit rather than a moving branch so dependency resolution
stays reproducible, and use the minimum Zig release the package declares
(0.16.0). The `tests/package_consumer` fixture compiles this exact snippet in
CI, and `scripts/check_package_paths.sh` repeats it from a clean `zig fetch` of
the package. [Operations](docs/operations.md#use-as-a-zig-dependency) covers
path dependencies, archive linking, and the C ABI contract.

## Shared-nothing by default

`App.cluster(worker_count)` gives every worker its own loop, connection pool,
request buffers, message regions, and queues. There is no shared I/O ring and
no lock on the steady-state path. `worker_count` is the compiled capacity;
`build_cluster_from_environment` resolves `UWEBZOCKETS_WORKERS` or the platform
CPU count, and `ClusterOptions.worker_count` selects an explicit count. Only
active workers allocate memory or threads.

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a pinned worker") catch {};
}

pub fn main(init: std.process.Init) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .build_cluster(std.heap.page_allocator, 4, .{});
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Cluster.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    try group.listen("0.0.0.0", 3000);
    try group.run();
}
```

Workers share the port through `SO_REUSEPORT` (Linux/macOS) or `SO_REUSEADDR`
(Windows fallback in code), are pinned to
distinct physical cores where the platform
allows it, and set `TCP_DEFER_ACCEPT` and `TCP_QUICKACK` to keep the loop
asleep through handshakes and to avoid delayed-ACK stalls. Details and the
platform matrix are in [docs/architecture.md](docs/architecture.md).

A worker group can also terminate TLS itself. Call `enable_https` with PEM
files, or `enable_https_ephemeral` for development, after `configure` and
before `listen`; every worker then owns its own TLS context and loads or
generates its credentials once at startup. TLS clusters are TCP-only:
HTTP/3/QUIC clustering is not supported.

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, response: *uz.Response) void {
    response.text("hello from a TLS worker") catch {};
}

pub fn main(init: std.process.Init) !void {
    var cluster = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .build_cluster(std.heap.page_allocator, 4, .{});
    defer cluster.deinit();

    const Group = @TypeOf(cluster);
    try cluster.configure(struct {
        fn routes(worker: *Group.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    try cluster.enable_https("certs/fullchain.pem", "certs/privkey.pem");
    try cluster.listen("0.0.0.0", 8443);
    try cluster.run();
}
```

`zig build tls_cluster -Doptimize=ReleaseSafe` starts the equivalent example
with the platform CPU count by default (override with
`UWEBZOCKETS_WORKERS`) and per-worker ephemeral certificates on
`https://127.0.0.1:8443/`. [docs/tls.md](docs/tls.md#tls-enabled-clusters)
covers ownership, lifecycle, and error names.

## Configure capacities, not bytes

`ServerConfig` presets and the fluent builder replace byte arithmetic with named
limits. `build` performs exactly one application allocation: the contiguous
slab behind the pool, request buffers, message regions, write queues, and
optional compression scratch.

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();

_ = try server.get("/health", health);
try server.listen("0.0.0.0", 3000);
try server.run();
```

| Preset | Connections | WebSocket message | Write queue | Request body |
| --- | ---: | ---: | ---: | ---: |
| `Presets.microservice` | 256 | 8 KiB | 16 KiB | 64 KiB |
| `Presets.websocket_chat` | 512 | 32 KiB | 32 KiB | 4 KiB |
| `Presets.file_server` | 128 | 4 KiB | 512 KiB | 8 KiB |

`with_max_request_line_size`, `with_max_header_size`, and `with_max_header_count`
extend the HTTP/1 request limits; fields beyond the inline 64 get per-connection
slab storage. `max_header_size` also sizes HTTP/3 request headers, so enabling
HTTP/3 requires it to be at most 65535. `with_max_route_nodes`, `with_max_pattern_routes`,
`with_max_middleware`, `with_max_route_path_size`,
`with_max_route_registry_size`, and `with_max_route_params` size the
slab-carved router and its capture spill. HTTP/2 metadata is sized by
`with_max_h2_header_block_size`, `with_max_h2_body_size`,
`with_max_h2_response_header_size`, and `with_max_h2_response_header_count`;
HTTP/3 uses `with_max_h3_body_size`, `with_max_h3_response_header_size`, and
`with_max_h3_response_header_count`. Oversized input gets a structured
rejection instead of a dropped connection:

```json
{"error":{"code":"payload_too_large","message":"Request body exceeded the 64KB limit. Consider increasing 'max_body_size' in ServerConfig.","limit_bytes":65536}}
```

The full capacity table, slab layout, and backpressure model are in
[docs/memory_model.md](docs/memory_model.md).

## Request helpers

`Request` and `Response` carry allocation-free helpers for the common API
surface. Register routes on the path only (`/search`); the query string is
already split off into `Request.query`. Then read pairs zero-copy:

```zig
fn search(req: *uz.Request, res: *uz.Response) void {
    const params = req.query_params() catch return;
    const page = (params.get_int(u32, "page") catch null) orelse 1;
    var scratch: [96]u8 = undefined;
    res.json_buf(.{ .query = params.get("q") orelse "", .page = page }, &scratch) catch {};
}
```

`Request.query_params()` and `Request.form()` slice query and form
pairs out of the bounded buffer with SIMD byte scans into a fixed
struct-of-arrays view; `query.QueryParamsOf(capacity)` and
`Request.query_params_of(capacity)` raise that capacity at compile time.
`percent_decode` and `form_decode` decode escapes into caller-owned scratch.
`Request.accepts()` scores the `Accept` field, `Response.json_value` writes
dynamic `std.json.Value` payloads, `Response.begin_json()` returns a streaming
chunk writer for arbitrarily large JSON without allocation, and
`Response.begin_stream()` pulls a chunked body from an application callback as
the transport drains, so response size never depends on the write-queue size.
`Response.end_gzip` compresses from a per-worker codec pool enabled with
`with_http_compression(true)`; the codec and bounded scratch are allocated at
startup, never on a request. Pipelined HTTP/1.1 responses and consecutive
WebSocket frames coalesce into the bounded write ring before one flush.
`errors.Problem` renders typed JSON error documents, `status.line` maps codes
to canonical status lines, `cache.etag` and `cache.is_not_modified` implement
conditional GET, `schema` validates decoded JSON against comptime rules, and
`cookie` adds a SIMD-accelerated `CookieJar` view plus versioned signing for
key rotation. HTTP/1.1 response heads are written as scatter parts, so header size
is bounded by the configured write queue instead of a fixed formatting buffer.
Every helper reuses the existing bounded buffers and stays off the heap on the
request path.

## Authentication, rate limiting, and shutdown

`middleware.Auth` validates Basic and Bearer credentials with constant-time
comparison; `middleware.RateLimit` charges caller-owned token buckets keyed by
a custom function, a header your proxy sets, or a constant, and answers an
empty bucket with `429 Too Many Requests` plus `Retry-After`. Both are
allocation-free:

```zig
var credentials = uz.middleware.auth(.{
    .realm = "ops",
    .basic = &.{.{ .username = "admin", .password = "secret" }},
});
_ = try app.use(&credentials, uz.middleware.Auth.handler);

var buckets: [256]uz.middleware.RateLimitBucket = @splat(.{});
var limiter = uz.middleware.rate_limit(init.io, .{
    .rate_per_second = 20,
    .burst = 40,
    .key_header = "x-api-key",
}, &buckets);
_ = try app.use(&limiter, uz.middleware.RateLimit.handler);
```

`try app.catch_shutdown_signals();` installs a process-wide SIGINT/SIGTERM
watcher (Windows console control on Windows) that drains the server through the
normal shutdown path; clusters use `Cluster.catch_shutdown_signals()`.
[docs/http.md](docs/http.md#middleware) and
[docs/api.md](docs/api.md#graceful-shutdown-signals) cover both.

## Terminal development log

`with_dev_log(true)` prints the `µWEBZOCKETS` wordmark and a Vite-style ready
summary before the first accepting listener: `µWebZockets v2.1.0  ready in
0.6 ms` followed by the `→ Local:` line; the elapsed time scales
through nanoseconds, microseconds, milliseconds, and seconds. The wordmark
collapses to a one-line `µWebZockets` mark when the terminal is narrower than
the block art. Requests then log Vite-style as `HH:MM:SS | [METHOD] /path :
STATUS`, plus colored connection, WebSocket, and metric lines. Everything
renders from fixed stack buffers, and each worker thread writes every record
through its own thread-local sink as soon as it is recorded, so the terminal
reflects the server in real time without allocating on the event loop. Failed
or short writes drop the record instead of retrying.

`with_watch_paths(&.{ "src", "examples" })` watches those directories
recursively and prints a `watch` line for every save, create, and delete, so
edits show up as they happen. Watch paths require `with_dev_log(true)`. Linux
reports changes in real time from inotify; every other target scans the roots
on a 500 ms loop timer. `.git`, `.zig-cache`, `zig-out`, `zig-pkg`,
`node_modules`, and `.cache` are skipped.

```zig
var server = try uz.Server.builder(init.io)
    .with_observability(true)
    .with_dev_log(true)
    .build(std.heap.page_allocator);
defer server.deinit();

_ = try server.get("/", hello);
try server.listen("0.0.0.0", 3000);
try server.run();
```

Every record carries an explicit direction (`data_in` or `data_out`) and a
named event payload. `ServerConfig.enable_dev_log` defaults on; the default
stderr sink stays quiet when stderr is not a terminal, and `false` silences
every development-log write. `App.log_metrics` adds a snapshot of the
bounded Prometheus registry, and `App.set_dev_log_file` redirects output from
stderr. Every example shows the log when run in a terminal.

## TLS without certificate files

`init_https_ephemeral` generates an ECDSA P-256 key and a self-signed
certificate in memory with BoringSSL, so a local HTTPS server needs no
`openssl` step, no `.pem` files, and no configuration:

```zig
var server = try uz.App(128).init_https_ephemeral(init.io);
defer server.deinit();

_ = try server.get("/", hello);
try server.listen("0.0.0.0", 3443);
try server.run();
```

```sh
curl -k https://127.0.0.1:3443/
```

The generated certificate covers `localhost`, `127.0.0.1`, and `::1`, and
carries the `serverAuth` extended key usage browsers require. The context
stays TLS 1.3 only with the usual `h2`/`http/1.1` ALPN policy. Generation
happens once at startup; connection setup, handshakes, and the request path
remain allocation-free, and nothing is written to disk. `zig build
https_server` runs the example, and `zig build http3_server` starts HTTP/3 on
UDP 8443 with the same in-memory credentials.

Keep `init_https`/`init_http3` for real certificates. `tls.CertificateNames`
customizes the names embedded in generated certificates, and the C ABI exposes
`uwz_app_create_tls_ephemeral` and `uwz_app_create_http3_ephemeral` for the
same workflow. [docs/tls.md](docs/tls.md) covers the certificate lifecycle and
the production handoff.

### Client certificates (mTLS)

When the caller's identity must be proven before a request reaches a route,
`init_https_mtls` verifies the client chain against a CA bundle you provide and
fails the handshake closed before the HTTP parser sees a byte:

```zig
var server = try uz.App(128).init_https_mtls(
    init.io,
    "certs/fullchain.pem",
    "certs/privkey.pem",
    .{ .mode = .required, .ca_path = "certs/client-ca.pem" },
);
```

`tls.ClientAuth` selects `none`, `optional`, or `required` verification.
[docs/tls.md](docs/tls.md#client-certificates-mtls) covers modes, bundle
format, and error names.

## Outbound HTTP client

The same library carries a bounded HTTP/1.1 client over TCP and TLS. One
`client(N)` value owns `N` request slots and its own event loop; the plaintext
path allocates nothing, and a TLS fetch allocates its BoringSSL session once
per connection. HTTP/2 and HTTP/3 clients are deliberately not provided:

```zig
var storage: uz.client.FetchStorage = .{};
const outcome = try uz.client.fetch_blocking(init.io, .{
    .method = .get,
    .host = "127.0.0.1",
    .path = "/status",
}, .{ .port = 8080 }, &storage);
```

Responses support `Content-Length`, chunked transfer coding with trailers, and
close-delimited bodies; trust fails closed (`verify = true` requires a CA path,
because BoringSSL ships no default trust store). The full contract, including
timeouts, capacities, and failure kinds, is in
[docs/client.md](docs/client.md).

## Examples

| Step | Shows |
| --- | --- |
| `zig build hello_world` | Minimal HTTP/1.1 route on `App` |
| `zig build https_server` | HTTPS on port 3443 with an in-memory certificate |
| `zig build shared_nothing_cluster` | Four pinned workers, one slab each |
| `zig build tls_cluster` | Runtime-selected TLS workers (CPU count by default) on port 8443 with per-worker certificates |
| `zig build basic_microservice` | `Presets.microservice` with JSON helpers |
| `zig build custom_builder` | Fluent overrides and the 50 MiB body path |
| `zig build chat_server` | WebSocket pub/sub with bounded topics |
| `zig build rpc_server` | Typed JSON-RPC procedures |
| `zig build http3_server` | HTTP/3 over QUIC with an in-memory certificate |

Every step appends `-Doptimize=ReleaseSafe` for production builds. Sources live
in [`examples/`](examples/), with walkthroughs in
[`examples/readme_examples_test.md`](examples/readme_examples_test.md).

## Documentation

| Document | Contents |
| --- | --- |
| [Getting started](docs/getting_started.md) | Install, first server, first route, first WebSocket, examples |
| [API guide](docs/api.md) | Application types, lifecycle, routing, middleware, ownership rules |
| [HTTP](docs/http.md) | HTTP/1.1 parsing, routing, middleware, helpers, static files |
| [HTTP/2](docs/http2.md) | Frames, HPACK, flow control, RFC 8441 tunnels |
| [HTTP/3 and QUIC](docs/quic.md) | QPACK, WebTransport status, RFC 10008 `QUERY` |
| [WebSocket](docs/websocket.md) | RFC 6455, RFC 7692 compression, pub/sub, heartbeats |
| [JSON-RPC](docs/json_rpc.md) | Typed procedures, batches, capacities |
| [TLS](docs/tls.md) | Ephemeral and production credentials, worker-group TLS, ALPN, 0-RTT, mTLS |
| [Client](docs/client.md) | Outbound HTTP/1.1 client over TCP and TLS |
| [Deployment](docs/deployment.md) | Credentials, capacity sizing, hardening, shutdown, platforms |
| [Roadmap](docs/roadmap.md) | What 1.7.0 closed and which boundaries are deliberate |
| [Troubleshooting](docs/troubleshooting.md) | Rejections, TLS and client failures, cluster and signal issues |
| [Architecture](docs/architecture.md) | Shared-nothing workers, affinity, TCP tuning, transports, shutdown |
| [Memory model](docs/memory_model.md) | Startup slab, SoA layouts, capacity limits, backpressure, rejections |
| [Operations](docs/operations.md) | Build, sanitizers, fuzzing, C ABI, dependency use, platform tiers |
| [Codebase](CODEBASE.md) | File-by-file map of the implementation |
| [CI pipeline](CI_CD_PIPELINE.md) | Workflow gates and verification matrix |
| [libxev fork policy](docs/libxev_fork.md) | Upstream mirror, integration branch, patch ledger, migration |

## Platform support

- Supported: Linux and macOS on `x86_64` and `aarch64`; built and tested by CI.
- Native Windows coverage: `x86_64-windows-gnu` now has compile gates plus a
  `windows-2025` runtime job. The 1.9.0 accept and queued-close fixes are
  recorded in
  [ADR 0004](docs/adr/0004-windows-iocp-accept-and-queued-close.md). Official
  support is claimed only after that job is green for the release commit; no
  Windows binaries are published.
- Community targets: FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD share the
  build graph without dedicated CI runtime coverage.
- Shared-nothing clustering is fully supported on Linux; macOS runs unpinned
  because the platform exposes no hard-affinity API.

## Project status

The repository CI covers Zig builds and tests, RFC 6455 behavior, HTTP/3
interop, HTTP/1.1 conformance, deterministic fuzz smoke tests, an
OSS-Fuzz/ClusterFuzzLite build, and a markdown link gate over every developer
document. The throughput workflow compares the optimized `hello_world` server
with the main branch on the same runner; it is a regression guard, not a
universal performance claim. Releases are source tags: there are no
per-platform binary archives, and consumers use `zig fetch` so the package
manager builds the pinned dependencies. The current source tree may include
unreleased changes, and [docs/roadmap.md](docs/roadmap.md) records what each
release closes and which boundaries are deliberate or blocked upstream.

[![Test](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml)
[![Autobahn Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml)
[![h1spec Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml)
[![Benchmark](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml)

BoringSSL provides TLS, libxev drives non-blocking I/O, zslay 0.2.1 provides the
WebSocket frame state machine, and lsquic provides QUIC. Zig compiles BoringSSL,
lsquic (with ls-qpack and ls-hpack), libdeflate, and zlib from pinned packages,
so the build needs only Zig. Use a released tag or pin an exact source commit.

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Security reports must follow
[SECURITY.md](SECURITY.md).
