# Security Policy

## Supported versions

Security fixes apply to the current development revision and the latest
released minor line. Older snapshots and unsupported raw transport internals
do not receive backports.

| Version | Supported |
| --- | --- |
| Current development revision | Yes |
| Latest released minor line | Yes |
| Older tagged releases | No |
| Earlier snapshots | No |

## Reporting a vulnerability

Do not open a public issue, pull request, discussion, or Autobahn report that
contains an undisclosed vulnerability.

Send a private report to
[trananhquan1009@gmail.com](mailto:trananhquan1009@gmail.com) or
[noah1109.tran@gmail.com](mailto:noah1109.tran@gmail.com). Include:

- the affected revision and target platform;
- a minimal reproducer or packet sequence;
- expected and observed behavior;
- impact and preconditions;
- logs or sanitizer output with secrets removed; and
- any suggested mitigation.

The maintainers will acknowledge the report, reproduce and assess it, prepare a
fix and regression test, and coordinate disclosure. Response time depends on
severity and maintainer availability; no fixed service-level agreement is
offered.

## Security boundaries

The live network surface is HTTP/1.1, bounded HTTP/2, RFC 6455 WebSockets,
RFC 7692 per-message deflate, HTTPS, and bounded HTTP/3 request/response
routing. HTTP/2 accepts plaintext prior knowledge or TLS ALPN and caps each
connection at eight streams. Raw QUIC engine, stream, packet, and QPACK
callbacks under `src/quic` are internal and are not a supported consumer
interface.

The outbound client (`src/client`) is HTTP/1.1 only and is also part of the
security surface: it verifies certificates when `verify` is enabled, requires a
caller-supplied trust store because BoringSSL ships none, applies SNI and
hostname or IP verification per session, and refuses to reuse one client with
different trust rules. `verify = false` is a development-only mode. The client
does not present a certificate, follow redirects, store cookies, use proxies,
or retry; callers own those policies.

Mutual TLS (`init_https_mtls`) verifies client chains against the caller's CA
bundle and fails the handshake closed in `required` mode. Authentication and
rate-limiting middleware compare credentials in constant time, fail closed on
malformed or duplicate fields, and rely on caller-owned fixed storage.
`App.catch_shutdown_signals` and `Cluster.catch_shutdown_signals` install one
process-wide watcher; deployments that already manage signals must not install
a second one.

`http3_extensions` and `webtransport` provide bounded validators and wire
helpers. They are not connected to the live lsquic listener, which rejects
extended CONNECT; they do not establish WebTransport, server push, or
application-datagram support. RFC 10008 is the separate HTTP `QUERY` method
supported by the router. Live transports reject QUERY requests without a
syntactically valid `Content-Type` before the route handler runs.

Deployments must set connection, WebSocket message, write-queue, and HTTP/3
response capacities appropriate for their traffic, select an appropriate idle
timeout, and apply normal operating-system resource limits. The default idle
timeout is 120 seconds; `ConfiguredAppWithTimeout` can change it or disable
idle sweeping with zero. HTTP/3 additionally bounds decoded headers, request
bodies, packet buffers, connections, and active streams.

Parameterized routing stores at most 16 borrowed captures per request and 64
patterns per router. Global middleware is capped at 32 entries. Asynchronous
response tokens are generation-checked and one-shot; they are confined to the
owning event loop, invalidate on transport reuse, and must not be completed
from another thread without first marshalling work to that loop.

Per-message deflate is disabled by default. When enabled, negotiation requires
client and server no-context-takeover, compressed input and output use separate
caller-owned scratch slices, and decompression cannot exceed the configured
message capacity. An 8-bit server compression window is declined because zlib
cannot emit it reliably; incoming 8-bit client streams retain the same
decompression bound.

Request and WebSocket message slices are borrowed from fixed connection
storage. Request and parameter slices remain valid until a synchronous handler
returns or its asynchronous token completes; WebSocket message slices remain
valid only for their callback. The application value itself must remain at a
stable address after `listen` or `listen_udp`.

The C ABI in `include/uWebZockets.h` uses opaque handles and copied route paths,
but returned `uwz_slice` values are still borrowed. Applications must destroy
opaque handles explicitly and handle every nonzero `uwz_error`. Copy request
fields and route parameters into caller-owned storage before a C callback
returns if asynchronous work needs them. Copy async tokens, marshal completion
to the owning event loop, and complete each generation at most once.

The project uses bounded buffers and protocol compliance tests to reduce risk,
but these controls do not guarantee the absence of defects. Consumers should
pin exact source or release hashes, review `THIRD_PARTY_NOTICES.md`, and test
the library under their own workload before production deployment.

Application teardown is completion-driven: stop accepting new work, cancel and
drain registered libxev operations, then release TLS, QUIC, event-loop, and slab
storage. Consumers should call `deinit` through `defer` and must not copy or move
an `App` after `listen` or `listen_udp` has registered callbacks.

CI runs the centralized Zig and C ABI graph with ASan, UBSan, and leak
detection on native Linux while instrumenting the pinned C/C++ dependencies
and local C shim. A separate, mutually exclusive x86_64 Linux
MemorySanitizer job rebuilds those C/C++ components with origin tracking and
executes a focused dependency-boundary smoke. It does not claim MSan
instrumentation of Zig code or full C ABI behavior; the dependency-boundary
smoke is the permanent MSan contract dated 2026-10-19. Google
OSS-Fuzz/libFuzzer entrypoints exercise HTTP
framing, WebSocket masking, and QUIC/WebTransport packet boundaries; local
deterministic smoke seeds are retained. Autobahn, h1spec, and the pinned
curl/ngtcp2 plus aioquic HTTP/3 gate add protocol coverage. Deployments should
still perform workload-specific QUIC load testing.

Cross-platform support covers Linux and macOS on `x86_64` and `aarch64`.
Windows (`x86_64-windows-gnu` / MinGW ABI) has a native job that compiles the
complete ReleaseSafe test/ABI graph, builds the static libraries, and runs the
test suite; official support follows a green runtime job for the release
commit. No Windows binaries are published. FreeBSD, NetBSD, OpenBSD, and
DragonFlyBSD share the build graph but are not officially supported and have
no dedicated runtime CI coverage. Treat unverified platforms as community
builds and validate them against your own deployment requirements.

## Disclosure

Please allow a reasonable remediation and release window before publication.
Security advisories will credit reporters who request attribution and will
describe affected versions, impact, and upgrade guidance without exposing
unnecessary exploit detail before a fix is available.
