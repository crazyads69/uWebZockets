# Deployment Guide

This is the production checklist for a µWebZockets service: credentials,
capacity sizing, observability, shutdown, platforms, and the security posture
the framework expects you to configure.

## 1. Credentials

| Situation | API | Credentials |
| --- | --- | --- |
| Production | `init_https` / `init_http3` | PEM files you provide |
| Mutual TLS | `init_https_mtls` | PEM server files plus a client CA bundle |
| Local development | `init_https_ephemeral` / `init_http3_ephemeral` | Generated in memory |
| TLS cluster, production | `Cluster.enable_https` | PEM files loaded into one context per worker |
| TLS cluster, development | `Cluster.enable_https_ephemeral` | Generated per worker; development only |

- The certificate argument is a PEM chain, leaf first. The key is a PEM private
  key; `SSL_CTX_check_private_key` runs at startup so a mismatched pair fails
  fast.
- TLS is 1.3 only. HTTP/1.1 and HTTP/2 share one context advertising `h2` then
  `http/1.1`; HTTP/3 uses a separate context advertising `h3`.
- TCP enables 0-RTT early data and dispatches only safe methods (`GET`, `HEAD`,
  `OPTIONS`, `TRACE`) before the handshake confirms; anything else gets
  `425 Too Early`.
  QUIC keeps early data disabled.
- There is no hot certificate reload. Rotate by rolling a new process; keep the
  old one draining until it exits. This is a dated decision, not an omission;
  see [ADR 0003](adr/0003-tls-cluster-operational-boundaries.md) and
  [tls.md](tls.md).
- A TLS cluster follows `build_cluster` -> `configure` -> `enable_https` ->
  `listen` -> `run` -> `request_shutdown` or a shutdown signal -> `deinit`.
  Call one enable function exactly once before `listen`; each worker reads the
  PEM files once at startup, so credential rotation is a rolling restart. Hot
  reload remains out of scope under
  [ADR 0003](adr/0003-tls-cluster-operational-boundaries.md).
- `enable_https_ephemeral` generates a distinct self-signed certificate per
  worker and is for development only. `enable_https` does not configure client
  certificates. HTTP/3/QUIC clustering is not supported; `init_http3` and
  `listen_udp` remain single-application APIs.

## 2. Size capacities for your traffic

Every pool is fixed at startup. Sizing is the deployment's most important
decision because exhaustion is explicit, not dynamic.

| Preset | Connections | WebSocket message | Write queue | Request body |
| --- | ---: | ---: | ---: | ---: |
| `Presets.microservice` | 256 | 8 KiB | 16 KiB | 64 KiB |
| `Presets.websocket_chat` | 512 | 32 KiB | 32 KiB | 4 KiB |
| `Presets.file_server` | 128 | 4 KiB | 512 KiB | 8 KiB |

- A plaintext connection with a `max_body_size` of 1 MiB costs roughly that
  much request buffer per connection in the slab. Raise `max_body_size` only as
  far as your largest legitimate upload.
- WebSocket message capacity is per connection; chat servers need more than
  microservices.
- The write queue bounds response buffering. `begin_stream` lets responses
  exceed it without raising it.
- HTTP/2 and HTTP/3 have their own per-stream capacities
  (`with_max_h2_*`, `with_max_h3_*`).
- Oversized input gets a structured rejection (`413`, `431`) that names the
  limit; see [memory_model.md](memory_model.md) for the slab layout and the
  full capacity table.

## 3. Harden the request path

- Put authentication in front of sensitive routes with `middleware.Auth`.
- Rate-limit by a server-derived key (`key_fn` or `key_constant`, or a header
  your proxy sets). Client-controlled keys can rotate around the limiter.
- Apply `middleware.SecurityHeaders` and `middleware.Cors` deliberately rather
  than globally if you serve both browser and service traffic.
- Keep the default idle timeout (120 s) or set one that matches your clients;
  heartbeats close dead WebSocket peers.
- Reject early data beyond safe methods: this is automatic, but keep
  idempotency in mind for `GET` handlers that mutate state.
- Prefer `with_dev_log(false)` in production unless you bind a log file; the
  default stderr sink stays quiet when stderr is not a terminal.

## 4. Observability

```zig
var server = try uz.Server.builder(init.io)
    .with_observability(true)
    .build(std.heap.page_allocator);
```

- The bounded Prometheus registry renders without allocating. Counters:
  `uwz_connections_accepted`, `uwz_connections_closed`, `uwz_http_requests`,
  `uwz_ws_messages`. HTTP/1.1 and HTTP/2 advance request counters; HTTP/3 emits
  request records but does not advance the registry yet.
- `App.log_metrics()` writes a registry snapshot through the development log.
- The development log is allocation-free and per-worker; it never blocks the
  loop on a slow terminal (failed or short writes are dropped and counted).
- The optional eBPF latency histogram is read when its map is pinned. The
  server data path always serves through the standard network stack; a
  `ServerConfig.transport = .kernel_bypass` request reports reason
  `.data_path_unwired`, and the AF_XDP transport module stays available to
  callers that drive it directly. See [operations.md](operations.md).

## 5. Shutdown and draining

```zig
try app.catch_shutdown_signals();
try app.run();
```

- A signal requests the same drain path as `App.shutdown`: stop accepting,
  cancel completions, drain connections, release the slab.
- `deinit` asserts drained state and panics if called from inside the loop.
  Always `defer app.deinit()`.
- Clusters install one watcher with `Cluster.catch_shutdown_signals()` and
  request shutdown for every worker. After `run` returns, `state()` reports
  `stopped` and `first_failure()` names the first worker index, phase, and
  error. `deinit_checked()` is the supervisor-safe release path; keep one
  `Cluster` owner, do not copy or move it after the watcher/run starts, and
  keep it alive through release.
- A supervisor should send SIGTERM and wait for exit; there is no in-flight
  request deadline beyond the configured connection idle timeout.

## 6. Platforms

| Supported | Linux and macOS on `x86_64` and `aarch64` | Linux runs the hosted runtime/sanitizer matrix; the macOS test graph cross-compiles on demand, with no hosted kqueue runtime job |
| Native Windows coverage | `x86_64-windows-gnu` | Compile gates plus a `windows-2025` runtime test job; official support follows a green run for the release commit |
| Community | FreeBSD, NetBSD, OpenBSD, DragonFlyBSD | Share the build graph without dedicated CI |

- Shared-nothing clustering is fully supported on Linux. macOS runs unpinned
  because the platform exposes no hard-affinity API. The Windows
  `SO_REUSEADDR` fallback remains compiled and is exercised by the native job.
- Windows QUIC uses IOCP receives and Winsock sends; the native test job covers
  the transport path. The 1.9.0 accept and queued-close fixes are recorded in
  [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md).
- Sanitizer coverage is native Linux only. MemorySanitizer instruments the
  pinned C/C++ dependencies, not Zig code. The dependency-boundary smoke is the
  permanent MSan contract as of 2026-10-19: Zig 0.16 emits no MSan
  instrumentation, and full BoringSSL instrumentation would need a second TLS
  toolchain. Plan an independent review for Zig-side memory questions. See
  [CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md#memorysanitizer-contract-permanent-2026-10-19).

## 7. Dependencies and reproducibility

- `build.zig.zon` pins zslay, libxev, BoringSSL, lsquic, ls-qpack, ls-hpack,
  libdeflate, and zlib by immutable URL or commit plus a Zig package hash.
- libxev, lsquic, and h1spec follow the
  [maintained fork policy](dependency_forks.md): pins are full 40-hex commits
  or submodule gitlinks, never branches or tags, and every upstream stays
  read-only. The former libxev and lsquic overlays and the h1spec CI patch are
  removed.
- Pin a release tag or full commit in your own `build.zig.zon`; do not track a
  branch.
- The build needs only Zig 0.16.0; C/C++ dependencies compile with `zig cc` and
  `zig c++` from pinned sources.
- Release tags are source distributions: there are no per-platform binary
  archives. Consumers fetch a tag with `zig fetch`, and the package manifest
  builds the pinned dependency sources locally. Link metadata for
  `zig-out/lib` archives is in [operations.md](operations.md#build).

## 8. Verify before launch

The repository's gates are the baseline; reproduce them for your revision:

```sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
```

Plus the external gates: Autobahn (517/517 accepted), h1spec, and the HTTP/3
cross-implementation gate. The benchmark contract is a relative regression
guard (candidate median at least 90 percent of the baseline), not an absolute
throughput claim. Run your own load test against your capacity choices before
launching; see [CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md).

## 9. Security posture summary

| Control | Where |
| --- | --- |
| TLS 1.3 only, ALPN policy, safe-method 0-RTT | [tls.md](tls.md) |
| Client certificates (mTLS) | [tls.md](tls.md#client-certificates-mtls) |
| Authentication, rate limiting, CORS, security headers | [http.md](http.md#middleware) |
| Bounded parsing and structured rejections | [http.md](http.md), [memory_model.md](memory_model.md) |
| WebSocket compression limits and heartbeats | [websocket.md](websocket.md) |
| QUIC/HTTP/3 limits and early-data rejection | [quic.md](quic.md) |
| Disclosure process and supported versions | [SECURITY.md](../SECURITY.md) |

Report vulnerabilities privately as described in
[SECURITY.md](../SECURITY.md); do not open a public issue with an undisclosed
vulnerability.
