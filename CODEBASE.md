# µWebZockets Codebase

## Scope

µWebZockets 2.1.5 is a Zig 0.16.0 HTTP/1.1, HTTP/2, WebSocket, and HTTP/3
server library with bounded HPACK protocol storage. It combines an
event-driven cross-platform transport (POSIX and Windows IOCP), fixed-capacity
protocol state, a data-oriented router, and C libraries for TLS, compression, and QUIC.

The current design makes bounded resource use explicit. Startup allocates one
contiguous slab that holds the connection pool, per-connection HTTP/1.1 request
buffers, WebSocket message regions, response write queues, and optional
compression scratch. `ServerConfig` presets and `Server.builder` compute that
slab from named limits before allocating it once. The `max_body_size` limit
sizes the HTTP/1.1 request buffers; HTTP/2 stream bodies and HTTP/3 request
bodies keep their compiled 16 KiB transport slabs. Network callbacks then reuse
those regions without general-purpose allocation. WebSocket compression and
HTTP/3 allocate their fixed slabs when the feature is configured, before
listening begins. Route arrays are immutable after either listener starts, so
callbacks never observe a structural mutation.

Thread-per-core cluster workers each own one such slab, run one libxev loop,
and coordinate only through lock-free sequence rings. `ClusterState`,
`WorkerFailure`, `FailurePhase`, and `PublishReport` make lifecycle, failure,
and delivery outcomes explicit; `src/router/worker_group.zig` owns lifecycle
transitions, release claiming, borrowed thread start/join, and first-failure
capture. Physical-core affinity, `SO_REUSEPORT`,
`TCP_DEFER_ACCEPT`, and `TCP_QUICKACK` are applied during startup and accept;
no mutex or spinlock remains on the steady-state I/O path.
libxev is reached through `src/core/xev.zig`, which selects io_uring when the
kernel permits it and otherwise degrades to epoll so containers without
io_uring still start and serve.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are expressed as small functions with explicit input
   and output state. Stateful I/O remains localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. Non-blocking I/O (epoll, io_uring, kqueue, and IOCP via libxev) drive callbacks.
   Zig's C and C++ toolchain compiles the vendored libraries from pinned sources.
5. WebSocket masking operates on native SIMD vectors before handling the scalar
   tail.

## Type readability

Type surfaces are named, explicit, and flat. Union payloads, callback fields,
and partial-configuration records are declared once with a one-line doc comment
instead of appearing inline: the HTTP/2 `Event` union uses `HeadersEvent`,
`DataEvent`, `GoAwayEvent`, `StreamResetEvent`, `WindowUpdateEvent`, and
`DiscardedDataEvent`; `Response` fields use `Http2EndFn`, `Http3WriteFn`, and
`AsyncCompleteFn`; `WsBehavior` uses the named `Ws*Callback` aliases;
`ServerConfig.with` takes the explicit `ServerConfig.Overrides` record instead
of reflection over `anytype`; transport callback fields use `CloseCallback` and
`TickCallback`. Aliases are zero-cost and additive: exported names, field
order, defaults, wire behavior, and capacities are unchanged. Comptime
factories remain for capacity and platform specialization only.

## Layout

```text
uWebZockets/
├── build.zig                 # thin versioned graph injector
├── build.zig.zon             # Zig 0.16 package manifest
├── builds/
│   ├── orchestrator.zig        # target selection and aggregate steps
│   ├── vendor/
│   │   ├── root.zig            # artifact wiring and the translated C module
│   │   ├── boringssl.zig       # BoringSSL source lists, defines, and C++ flags
│   │   ├── lsquic.zig          # assembled lsquic tree and sources
│   │   ├── libdeflate.zig      # libdeflate sources
│   │   └── zlib.zig            # bundled zlib sources
│   ├── sanitizers.zig          # ASan/MSan runtime configuration
│   ├── testing.zig             # unit, C ABI, h1spec, and Autobahn steps
│   ├── fuzzing.zig             # deterministic and OSS-Fuzz targets
│   ├── examples.zig            # example executables and run steps
│   └── targets/
│       ├── native.zig         # TCP, io_uring/IOCP, TLS, and QUIC graph
│       ├── wasm.zig           # freestanding and WASI edge graph
│       └── ebpf.zig           # XDP redirect and latency histogram objects
├── flake.nix                 # native GNU/musl and macOS packages
├── docs/                     # architecture, TLS, protocols, client, deployment, guides
├── include/uWebZockets.h     # versioned C ABI declarations
├── src/
│   ├── root.zig              # supported public API
│   ├── version.zig           # single Zig source of truth for the release version
│   ├── c_api.zig             # exported C ABI facade (handlers in c_api/)
│   ├── client/               # bounded HTTP/1.1 client (request builder, parser, transport)
│   ├── core/                 # libxev I/O plus transport-neutral protocol core
│   │   ├── affinity.zig      # physical-core selection and thread pinning
│   │   ├── ktls.zig          # Linux kTLS and zero-copy file transfer
│   │   ├── signal.zig        # graceful-shutdown signal watcher
│   │   └── udp.zig           # completion-owned UDP/QUIC transport
│   ├── crypto/               # bounded BoringSSL TLS, ephemeral certificates, Web Crypto
│   ├── edge/                 # WinterCG-compatible edge surface
│   ├── ffi/                  # bounded generation-checked shared memory
│   ├── http/                 # strict HTTP/1.1 parser, response writer, and request helpers
│   ├── http2/                # bounded frames, slab-carved session storage, and HPACK
│   ├── router/               # slab-carved radix router, App API, config, builder, worker group
│   ├── rpc/                  # bounded JSON-RPC registry and dispatcher
│   ├── ws/                   # streams, pure backpressure, framing, pub/sub
│   ├── observability/        # Prometheus registry, terminal dev log, and eBPF reader
│   ├── xdp/                  # AF_XDP UMEM rings, TX path, and bypass policy
│   ├── quic/                 # lsquic HTTP/3, WebTransport, and datagram ring
│   └── tests/                # centralized ordinary Zig unit tests
├── fuzz/                     # libFuzzer ABI targets and local smoke drivers
├── oss-fuzz/                 # Google OSS-Fuzz build and corpus metadata
├── tests/
│   ├── autobahn/             # RFC 6455 target, Deno runner, and config
│   └── h1spec/               # HTTP/1.1 compliance target
├── examples/                 # HTTP, HTTPS, WebSocket, JSON-RPC, builder, and cluster examples
└── vendor/                   # h1spec compliance submodule
```

## Runtime data flow

```text
libxev accept/read
      |
      v
fixed connection slot ----> optional bounded TLS BIO pair
      |
      v
HTTP request accumulator --> strict parser --> middleware --> radix route
                                      |                       |
                                      |                       +--> bounded HTTP writer
                                      |                       +--> one-shot async token
                                      v
                             WebSocket upgrade
                                      |
                                      v
                          zslay frame state machine
                                      |
                     SIMD unmask + streaming UTF-8
                                      |
                                      v
                         callback / bounded pub-sub

UDP read/timer --> lsquic engine --> bounded QPACK header set --> same router
                                   |                           |
                                   v                           v
                            bounded body slab          structured H3 response
```

The connection pool owns a contiguous `TcpConnection` slab and a separate
activity bitmap. `src/router/config.zig` sizes one larger contiguous region:
pool state, request buffers, WebSocket message storage, write queues, and
optional compression scratch. `ConfiguredApp` and the `Server.builder` carve
per-connection slices from that region. This avoids one allocation per accepted
socket and makes cleanup deterministic. A closed slot is not returned to the
freelist until its close, read, and write completions have all drained,
preventing an old completion from observing a reused connection.

Shutdown reverses that ownership graph. The application first rejects new
work, stops recurring timers, cancels accept/read/write/UDP completions, closes
descriptors through libxev, and runs the loop until every callback is disarmed.
`src/core/udp.zig` owns its fixed receive buffer, QUIC engine, read, timer,
cancellation, and close completions as one unit. Only after both transports
drain are TLS state, QUIC state, the loop, and contiguous slabs released.

The registration-to-handler map for native callbacks is in
[docs/callback_lifecycle.md](docs/callback_lifecycle.md).

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, bodies, and unsupported expectations. Pipelined bytes
are retained and parsed again after a response completes.

The router is a fixed-capacity runtime radix tree represented by parallel
arrays for segments, child/sibling/parent links, route bits, method handlers,
and WebSocket behaviors. An open-addressed static-route index (one FNV-1a hash
plus node slot per entry, sized to twice `max_nodes`) resolves exact routes
before the radix walk; a slot is accepted only after its node's stored segments
are compared byte for byte, so a hash collision falls through to the walk.
Pattern routes are unchanged. Up to 64 pattern
routes accept `:name` for one nonempty segment and a terminal `*name` for the
remaining path, including an empty remainder. A request owns 16 borrowed
capture slots and exposes them
through `Request.get_param`. Static specificity wins over parameter and
wildcard matches; malformed patterns and duplicate names fail registration.

Up to 32 global middleware callbacks execute in registration order and stop
explicitly or when a response starts. Routes can use the original synchronous
callback, an explicit context pointer, or a generation-checked asynchronous
token. A pending token prevents request-buffer or HTTP/3 stream reuse and can
complete exactly once on its owning event loop. The router also supports HEAD
fallback, OPTIONS, `Allow`, and an `any` fallback. Route strings and callback
contexts have different ownership: route strings are copied during
registration, while callback contexts remain borrowed and must outlive the
application.

Response metadata is validated against control-character injection and
ambiguous `Content-Length` or `Transfer-Encoding`. Writes enter a bounded ring
queue and handle partial kernel writes. A fully drained ring normalizes its head
to keep the next logical write contiguous instead of creating a delayed-ACK
wrap split. Producers observe `error.WouldBlock` instead of causing unbounded
memory growth. Chunk headers, bodies, and terminators are copied into that ring
as parts, so no per-connection chunk scratch allocation or fixed 8 KiB chunk
ceiling is needed.

`src/http/middleware.zig` also carries the built-in `Auth` and `RateLimit`
handlers. `Auth` compares Basic and Bearer credentials in constant time after
decoding Basic into bounded stack storage, and fails closed on missing,
duplicate, or malformed fields. `RateLimit` is a fixed-state token bucket over
caller-owned storage: refill math is pure and clamped, a full table evicts the
oldest key and starts it empty so key rotation cannot reset a budget, and the
handler reads the monotonic clock at the middleware boundary.

## Client

`src/client/` is a bounded HTTP/1.1 client: `request.zig` builds the head,
`http1.zig` is a pure response parser (content-length, chunked with trailers,
close-delimited, 1xx handling), and `connection.zig` owns the libxev connect,
read, write, timer, and cancel lifecycle per slot. `src/crypto/tls_client.zig`
provides the BoringSSL client context with SNI and hostname verification.
Storage lives entirely in the `client(N)` slab; the plaintext steady state
allocates nothing, and a TLS fetch allocates its session once per connection.
A terminal loop failure abandons in-flight slots so `deinit` stays valid.

## Shutdown signals

`src/core/signal.zig` installs a process-wide graceful-shutdown watcher. On
POSIX a self-pipe is written by an async-signal-safe handler and watched through
a libxev file poll; on Windows a console-control handler sets an atomic and
wakes the loop through a libxev async. The self-pipe write descriptor and the
Windows handler state are documented OS singletons, since signal handlers
cannot capture context. `App.catch_shutdown_signals` and
`Cluster.catch_shutdown_signals` bridge the watcher into the normal shutdown
path.

## JSON-RPC

`src/rpc/json_rpc.zig` implements transport-independent JSON-RPC 2.0 single
requests, notifications, and batches. `src/rpc/http.zig` adapts it to the
existing POST router. Procedure metadata is stored in
parallel fixed-capacity arrays, method bytes are copied into contiguous owned
storage, and an open-addressed index avoids allocation and pointer chasing on
dispatch. Registration is sealed at mount time so event-loop callbacks only
read the registry.

The protocol scanner borrows method parameters and IDs from the bounded HTTP
request body, while escaped member and method names use fixed local scratch.
Batches take a bounded syntax-only pass before dispatch so a malformed tail
cannot follow an already-committed procedure side effect. The pure dispatcher
accepts caller-owned output storage; the HTTP adapter uses one service-owned
bounded buffer and copies the final response into the connection's existing
write queue. Procedure handlers may parse parameters with an explicit
allocator, emit typed JSON results, or return standard and application-defined
faults. Each mounted service instance belongs to one event loop, so cluster
workers keep independent response buffers.

## WebSocket

zslay 0.2.1 validates frame structure and size limits and provides the pure
close-payload validator. µWebZockets adds strict server-side handshake
validation, fragmented-message assembly, streaming UTF-8 validation, close-code
handling, SIMD unmasking, and bounded writes. Control frames use a 125-byte
inline buffer. Message storage is provided by the owning
application and reused for the connection lifetime. Application message slices
are callback-scoped and outgoing text, control, and close frames are validated
before entering the transport queue.

RFC 7692 is opt-in through `WsBehavior.compression`. Extension negotiation is a
pure bounded parser that ignores malformed alternatives independently and
always selects client/server no-context-takeover. Full-window messages use
libdeflate; negotiated 9-14 bit server windows use preinitialized zlib streams
backed by fixed arenas. Incoming 8-15 bit client windows are decoded by the
bounded libdeflate path. Compressed input and decompressed output are capped by
per-connection receive scratch, send scratch, and message slices, so expansion
never causes a hot-path allocation and an outbound callback cannot corrupt an
in-progress compressed receive.

Pub/sub copies topic names into fixed internal storage, caps subscriptions, and
removes connection references during close. Published message bytes are never
retained after the callback returns.

## HTTP/2 and HPACK

`src/http2/connection.zig` provides a server-side frame state machine with a
fixed-capacity structure-of-arrays stream slab. It validates the client
preface, frame sizes and stream identifiers, CONTINUATION sequencing, padding,
SETTINGS, connection and stream flow-control windows, resets, ping, and GOAWAY.
Unknown extension frames are ignored according to HTTP/2 rules, while illegal
client push and state transitions fail closed.

`src/http2/hpack.zig` decodes HPACK requests and encodes responses into
caller-owned header, byte, entry, and dynamic-table storage. Integer and
Huffman decoding, table-size changes, pseudo-header ordering, field names,
connection-specific metadata, and header-list limits are checked before
dispatch. No HTTP/2 parser input is retained after its caller storage is
reused.

`src/core/tcp.zig` embeds one eight-stream server session per connection and
routes decoded requests through the same middleware and sync/async handlers as
HTTP/1.1. Plaintext sockets recognize the prior-knowledge preface; TLS prefers
ALPN `h2` and falls back to `http/1.1`. Peer resets invalidate retained async
tokens. RFC 8441 WebSocket tunneling is supported via extended CONNECT. The
parser and message buffers are connection-owned, so one HTTP/2 connection may
carry one active WebSocket tunnel alongside ordinary request streams.

## TLS, UDP, and HTTP/3

HTTPS uses BoringSSL TLS 1.3 with an in-memory BIO pair sized to match the
bounded output policy. The adapter validates context creation, propagates
backpressure, performs shutdown, and prefers HTTP/2 through ALPN.

`init_http3` creates transport-isolated TLS 1.3 contexts: the TCP context
advertises `h2` and `http/1.1`, and the QUIC context advertises only `h3`.
`listen_udp` constructs the completion-driven UDP transport and lsquic engine
in place only after the `App` has a stable address. The engine uses contiguous
freelist pools for streams, header sets, and outgoing packets, plus parallel
byte regions for decoded QPACK data, request bodies, response headers, and
response bodies. Pool capacity is the configured connection count; packet
capacity is
`max(16, connections * 4)`.

The header decoder validates pseudo-header ordering and uniqueness, lowercase
HTTP/3 names, URI targets, authority/Host agreement, connection-specific
fields, and content-length. It fills the existing `Request` directly rather
than producing temporary HTTP/1.1 text. Responses reuse the public `Response`
API and emit structured QPACK headers while preserving partial stream writes.
The QUIC TLS context explicitly disables 0-RTT, so replayable application data
is rejected before route dispatch.
QUIC global initialization is reference-counted under a small atomic lock. The
pinned curl/ngtcp2 and aioquic gate verifies a successful request, a valid
trailing field section, and `H3_MESSAGE_ERROR` rejection of malformed headers
while a healthy sibling stream completes on the same connection. Server push
and WebTransport are deliberately excluded.

`http3_extensions` exposes pure validators and bounded bookkeeping for RFC
9220 WebSocket extended CONNECT, server push IDs, and replay-aware early-data
policy. `webtransport` exposes draft-16 settings, CONNECT/origin checks,
sessions, stream and datagram association, capsules, flow control, and error
mapping. The pinned lsquic backend advertises only raw datagrams from the
required capability set, so these helpers are not connected to the live
HTTP/3 listener. The WebTransport constants model
draft-ietf-webtrans-http3-16 and do not claim live interoperability. RFC 10008
is the separate HTTP `QUERY` method supported by the router. All live
transports reject QUERY requests without a syntactically valid `Content-Type`;
the selected route enforces resource-specific media-type and content rules.

Windows QUIC datagrams are received through libxev IOCP UDP completions and
sent with the Winsock `WSASendTo` adapter. The native Windows workflow compiles
this path and runs the test suite. The 1.9.0 accept overlay and queued-close
fix are recorded in
[ADR 0004](docs/adr/0004-windows-iocp-accept-and-queued-close.md); official
support follows a green runtime job for the release commit.

## Development log

`src/observability/dev_log.zig` renders terminal diagnostics without
allocating. A `Sink` owns a fixed 4096-byte buffer and one bound output file;
`render` is pure and writes one `Record` through `std.Io.Writer.fixed` using
comptime format strings and ANSI colors. HTTP requests render Vite-style as
`HH:MM:SS | [METHOD] /path : STATUS` with a dim clock, cyan method, and
status-class color; connection, WebSocket, and metric events carry a colored
direction badge. Each record names the wall clock, severity, and an explicit
`Direction` (`data_in` or `data_out`) beside a named event payload. No ambient
logger state exists.

`thread_sink` returns the sink owned by the calling thread. Every worker owns
exactly one, so recording and writing need no lock or atomic, and the transport
reaches its sink without threading a logger pointer through every callback.
`Sink.record` writes the record immediately and drops oversized or failed lines
with a counter; `Sink.record_metrics` writes the whole snapshot as one batch.
`Sink.flush` issues at most one bounded `writeStreaming` per pending batch and
never retries a short write. `Sink.record_banner` writes the startup wordmark
once, followed by a blank padding line, and `Sink.record_ready` renders the
Vite-style summary: version, elapsed startup time, and local URL.
`src/observability/terminal.zig`
probes the terminal width so narrow outputs get a one-line `µWebZockets` mark
and redirected outputs keep the full block art. `ServerConfig.enable_dev_log`
defaults on; the app enables the worker sink unless the default stderr sink is
not a terminal, and in `listen`/`listen_udp` it writes
the summary in place of the `server listening` std.log line (`run` covers apps
that never listen); any pending bytes are drained when the loop exits.
`App.set_dev_log_file` binds an output that always records and
`App.log_metrics` records the Prometheus registry in slot order. With the
toggle false, the development log emits nothing at all.

`src/observability/file_watch.zig` streams `file_changed` records. Linux uses
inotify: the descriptor is read through the event loop and decoded against a
bounded directory table (64 watches, 4 KiB of paths). Other targets use a
portable scan backend driven by a 500 ms loop timer that diffs modification
time and size over a bounded file table (256 files, 16 KiB of paths) and
compacts its arena. Both skip `.git`, `.zig-cache`, `zig-out`, `zig-pkg`,
`node_modules`, and `.cache`; `ServerConfig.watch_paths` with
`builder.with_watch_paths` enables them and requires `enable_dev_log`.

## Build graph

`src/version.zig` is the single Zig source of truth for the release version;
the root `build.zig` derives its `std.SemanticVersion` from it and delegates
directly to `builds/orchestrator.zig`. `scripts/bump_version.sh` rewrites the
package manifest, the C ABI macros, the C/C++ tests, the documentation
headers, and the changelog skeleton, and `scripts/check_release_version.sh`
fails the lint workflow if any copy drifts. `builds/vendor/boringssl.zig`,
`builds/vendor/lsquic.zig`, `builds/vendor/libdeflate.zig`, and
`builds/vendor/zlib.zig` compile the
pinned C and C++ sources with Zig's own toolchain: BoringSSL reads the
generated source lists in `gen/sources.json`, lsquic imports the maintained
fork tree directly, and libdeflate and zlib use fixed source lists. No CMake,
Ninja, Go, Perl, Python, `patch`, or system zlib runs during the build. Sanitizer mode changes the compile flags on
the same graph, instruments BoringSSL, lsquic, libdeflate, zlib, and the local
C shim with ASan/UBSan, enables Zig's full C-UB checks, and preserves frame
pointers. A mutually exclusive x86_64 Linux MemorySanitizer mode rebuilds the
pinned C/C++ graph and local C shim with origin tracking, disables BoringSSL
assembly as upstream does, then runs a focused C dependency-boundary smoke. It
does not instrument Zig code or execute the complete C ABI test graph.

The Nix flake pins Nixpkgs 26.05, seeds Zig package dependencies
deterministically, and defines native and musl compile checks. `build.zig.zon`
pins zslay, libxev, BoringSSL, lsquic, ls-qpack, ls-hpack, libdeflate, and zlib
by immutable URL or commit plus Zig package hash.

Dependency provenance follows the [fork policy](docs/dependency_forks.md).
`build.zig.zon` pins `farbenbuilds/libxev` at
`cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16` with XEV-001 and
XEV-002, and `farbenbuilds/lsquic` at
`85bd081c9103c077a7cc98271d09334d0f1043d4` on `uwz/main` with LSQ-001 and
LSQ-002. The h1spec submodule points at
`999ba9e8f318b1c0ebbff1278b98bc5833f1af18` on `uwz/main` with H1S-001.
`patches/` and `vendor/lsquic_overlay` are deleted;
`scripts/check_dependency_forks.sh` checks all pins, dependency views, remote
commits, and the reviewed mirror records in `scripts/dependency_mirrors.env`.
`--exact-mirrors` additionally requires live upstream equality and runs on
release tags and the weekly drift workflow. See
[ADR 0005](docs/adr/0005-libxev-fork.md) and
[ADR 0006](docs/adr/0006-dependency-forks.md).

A downstream project can pin
an exact checkout at a local path without fetching the repository's
`vendor/h1spec` compliance submodule. Releases are source tags: the repository
publishes no per-platform binary archives, and consumers use `zig fetch` so the
package manager resolves and builds the pinned dependency sources.
`tests/package_consumer` imports the public module from a pinned local
path in CI. That module carries native link metadata and a clean static-library
edge that orders vendor builds without nesting dependency archives. The fixture
catches package-root and exported-name drift.
The build rejects any non-object member in the µWebZockets static archive.

Unit tests live only under `src/tests/`; `src/tests/main.zig` imports every
test file for `zig build test`. Its `fuzz_main.zig` Smith corpus also serves as
the dedicated root for extended `zig build fuzz` runs. Three
`LLVMFuzzerTestOneInput` targets cover HTTP framing, WebSocket masking, and
QUIC/WebTransport packet boundaries. `oss-fuzz/build.sh` links them with the
Google-provided fuzzing engine, while `zig build oss-fuzz-smoke` exercises
fixed local seeds. The reusable ClusterFuzzLite gate runs the OSS-Fuzz builder,
bad-build validation, and bounded execution for all three targets without
assuming hosted-service enrollment. It advertises address builds only: Zig
objects carry sanitizer coverage and `ReleaseSafe` checks, while the separate
library sanitizer matrix instruments the C/C++ graph with ASan/UBSan/MSan.

## Supported and internal API

The Zig surface exported from `src/root.zig` includes `App`, `ConfiguredApp`,
`ConfiguredAppWithTimeout`, `Request`, `Response`, `WebSocket`, `WsBehavior`,
`Opcode`, TLS configuration, chunked HTTP helpers, zero-allocation query and
form parsing, canonical status and typed JSON error helpers, `Accept`
negotiation, ETag helpers, CORS, security-header, authentication, and
rate-limit middleware, comptime schema validation, zero-copy cookie parsing
and signing helpers, and WebSocket masking. The
surface also includes `WsCompression`, fixed-capacity `json_rpc`,
completion-driven `udp`, bounded
`http2`, `http2_hpack`, `http3_extensions`, `webtransport`, `http3_available`,
`WebSocketStream`, BYOB and compression streams, abort controllers, Web Crypto,
shared memory, kTLS, AF_XDP, the allocation-free terminal `dev_log` sink, and
the transport-independent protocol core.
It also exposes `init_http3` and `listen_udp` through the application type. Live lsquic
engine, stream, packet, and QPACK callbacks remain internal.

The C ABI is declared by `include/uWebZockets.h` and implemented by
`src/c_api.zig`. It provides versioned opaque handles, versioned integer error
codes, explicit create/shutdown/destroy, synchronous and one-shot asynchronous
HTTP, ordered middleware, borrowed route parameters, bounded response,
WebSocket, TLS, HTTP/3, and publish operations. The ABI uses fixed capacities
of 1,024 connections, 64 copied route paths, and 32 middleware callbacks.
Async response tokens carry a generation and can complete exactly once on the
owning event loop.
This is a high-level server ABI rather than a one-to-one projection of the Zig
surface. Compile-time application configuration and the low-level `udp`,
HTTP/2, HPACK, HTTP/3-extension, and WebTransport helpers remain Zig-only.
