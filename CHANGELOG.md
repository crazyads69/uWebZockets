# Changelog

All notable changes to µWebZockets are documented in this file. The project
uses Semantic Versioning.

## [2.1.5] - 2026-10-25

API-hardening release for the thread-per-core manager. It makes cluster
lifecycle, worker failures, and publish outcomes typed and observable, moves
thread lifecycle into one internal manager, and cleans up the v2.2.0 plan.
There is no wire-protocol, TLS, capacity, or request-path change.

### Added

- Atomic `ClusterState` with `configured`, `running`, `stopped`, `releasing`,
  and `released`; `Cluster.state()`, `worker_count()`, and
  `worker_capacity()`.
- `FailurePhase`, `WorkerFailure { index, phase, err }`, `first_failure()`, and
  `failure_count()`. The first worker, spawn, or cleanup failure wins and is
  logged with its worker index and phase.
- `PublishReport { queued, dropped, notify_failed, first_dropped_worker }`,
  `attempted()`, `all_delivered()`, and `Cluster.publish_report()`.
  `Cluster.publish()` keeps its integer return and delegates to the report
  path.
- Named `Cluster.ConfigureCallback` replaces the `anytype` callback parameter.
  A generic route function must be specialized to the concrete `Worker` type;
  concrete function values keep their inferred error sets.
- `Cluster.run`, `publish`, and `publish_report` expose the named finite
  `RunError` and `PublishError` sets through `uz.cluster`.
- `Cluster.deinit_checked()` for supervisors that need a typed release error;
  `deinit()` keeps its panic contract.
- `Response.end_best_effort` and `Response.end_with_headers_best_effort` for
  callbacks whose ABI cannot propagate a response write failure.
- ADR 0007 records the lifecycle, failure-reporting, release-claiming, and
  publish-report decisions. `docs/api.md`, `docs/architecture.md`,
  `CODEBASE.md`, `README.md`, and `docs/roadmap.md` describe the new surface.

### Changed

- Lifecycle transitions, release claiming, borrowed thread-slice start/join,
  and first-failure capture moved into `src/router/worker_group.zig`. Thread
  storage and the public `threads`, `active_workers`, `thread_count`,
  `worker_failed`, and `deinitialized` fields remain in `Cluster`.
- Concurrent `deinit` calls claim release once; a second caller waits for the
  winning owner to publish `released` instead of freeing storage twice.
  Supervisor calls that touch worker storage register an in-flight call, and
  release waits for them before freeing.
- `cleanup_workers` stops the signal watcher and drains every worker loop
  before `run` publishes `stopped`. If a drain fails, `deinit` releases the
  surviving watcher after the loops are destroyed, so the free path remains
  safe without claiming a completed drain.
- `run` returns the original spawn error for a failed spawn and
  `error.ClusterWorkerFailed` for a worker event-loop or cleanup failure.
  Lifecycle misuse returns `ClusterRunning`, `ClusterStopped`, or
  `ClusterDeinitialized`; `publish` after `run` returns `error.ClusterStopped`.
- Worker-count and queue validation use the named `WorkerCountError`,
  `MessageError`, and `QueueError` sets. Cluster message validation runs once
  before any inbox is mutated. `build_cluster_from_environment` prefers an
  explicit `ClusterOptions.worker_count` over the environment, then the
  environment over the CPU count.
- Successful publishes count failed loop wakeups in `notify_failed` instead of
  reporting an unwoken message as delivered. Cluster publish and lifecycle
  calls use a SeqCst in-flight gate so release cannot free worker storage under
  a supervisor call; this cost is outside the HTTP request path and is not
  benchmarked by the HTTP throughput gate.
- Duplicate best-effort response helpers in static files and middleware were
  replaced by the canonical `Response` methods. A failed best-effort write now
  aborts the TCP connection or HTTP/2/3 stream instead of leaving the request
  unanswered or appending a second response to a partial frame.
- Dependency mirror validation now records the reviewed mirror commit in
  `scripts/dependency_mirrors.env`. Pull-request lint checks the record;
  release tags and the weekly `Dependency Mirrors` workflow require exact live
  upstream equality. The lsquic mirror was fast-forwarded to
  `555de41db3544706ffc3444d99f3d934295c70a0` after reviewing the two upstream
  ClientHello and stream-write fixes.
- lsquic and h1spec now use maintained downstream forks, following the libxev
  policy. `build.zig.zon` pins `farbenbuilds/lsquic` commit
  `85bd081c9103c077a7cc98271d09334d0f1043d4` on `uwz/main`, and the
  `vendor/h1spec` submodule points at `farbenbuilds/h1spec` commit
  `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` on `uwz/main`. `patches/` and
  `vendor/lsquic_overlay` are deleted; the fork checks verify every pin.
- ADR 0001 is accepted for HTTP/3 datagram and WebTransport implementation
  through the lsquic fork. The live path remains capability-gated until the
  2.2.0 compliance work lands.

### Fixed

- Worker failures retain the failing index, startup phase, and original error
  instead of a bare boolean.
- Full inboxes and failed loop wakeups are visible in the publish report
  instead of being hidden in a single accepted count.
- Concurrent `deinit` calls can no longer double-free worker storage, and
  supervisor calls are drained before worker storage moves.
- `message_queue.pop_copy` checks the actual message lengths before copying
  and leaves the message queued when it does not fit, closing a release-build
  out-of-bounds copy path without losing a message.

### Security

- Cluster wakeup now drains into queue-owned scratch instead of connection 0's
  WebSocket assembly buffer. This closes a path where a publish between two
  fragments could overwrite a live fragmented message or inject another
  topic's payload into it.
- No wire format or capacity limit changed. Cluster publish validation and
  bounded inboxes remain fail-closed; best-effort response failures now abort
  the TCP connection or HTTP/2/3 stream instead of leaving a partial response.

## [2.1.0] - 2026-10-24

Release that moves deadlines onto a per-worker hierarchical timing wheel,
parks delayed responses without blocking the loop, removes the libxev source
overlay in favor of the maintained fork, and closes the three v2.0.5 hot-path
follow-ups.

### Added

- `src/core/timer_wheel.zig`: allocation-free four-level timing wheel with
  256 one-millisecond slots, 64 256-ms slots, 64 16.4-second slots, and 64
  17.5-minute slots. Nodes are intrusive and embedded in the connection slab;
  deadlines beyond the level-3 range wait in an overflow list and enter the
  wheel when they come into range.
- `core/timer.zig` `Scheduler`: one persistent libxev timer per worker loop.
  It wakes on a bounded five-millisecond tick while deadlines exist, advances
  and cascades the wheel, and re-arms through the backend action instead of
  calling `run` inside its own callback. It never resets or reuses a
  completion, and `stop` lets the tick disarm instead of canceling. The old
  five-second pool sweep is gone for idle connections.
- `AsyncResponse.sleep` and `AsyncResponse.sleep_complete`: zero-allocation
  request parking backed by connection-owned timer nodes. HTTP/1 uses slot 0
  and HTTP/2 maps one slot per stream; an expired or reused generation fails
  closed.
- `examples/delay_server.zig` and the `delay_server` build step implement the
  bounded `/delay/:ms` profile.
- `ServerConfig.header_read_timeout_ms` and
  `Builder.with_header_read_timeout_ms`: incomplete request heads and bodies
  now have a separate deadline from a drained keep-alive connection.
- `middleware.RateLimitTable`, `rate_limit_indexed`, and caller-owned index
  and LRU storage. Indexed tables provide O(1) expected lookup and insert,
  exact-oldest eviction with lowest-index tie break, and an amortized rehash
  after churn.
- The HTTP/1 client response parser keeps a monotonic `scan` cursor across
  reads for status lines, header and trailer terminators, chunk sizes, chunk
  extensions, and split chunk CR/LF pairs.
- `ws.PubSubEngine` now keeps stable topic ids, per-topic intrusive subscriber
  lists, and open-addressed topic and subscription indexes. Publish work is
  proportional to the live subscribers of the published topic.

### Changed

- `build.zig.zon` pins `farbenbuilds/libxev` at
  `cbf01bc432a84cd91a99c1cb1031b46416d044c7` on the `uwz/zig-0.16`
  integration branch. The branch is based on upstream
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` and carries XEV-001 as a
  ledgered fork commit.
- `builds/targets/native.zig` imports the dependency's `xev` module directly;
  the `xev_tree` copy step, `vendor/libxev_overlay`, and
  `patches/libxev_iocp_accept_socket.patch` are deleted.
- `scripts/check_vendor_overlay.sh` now checks only the lsquic overlay.
  `scripts/check_libxev_fork.sh` verifies the full 40-hex fork commit, all four
  dependency views, and remote reachability.
- All four dependency views (`build.zig.zon`, `.json`, `.nix`, `.txt`) carry
  the fork URL, revision, Zig package hash, and Nix hash.
- The default `TcpConnection` gains one idle timer node and nine parking slots;
  the default slab total moves from `681_752_192` to `683_382_400` bytes.

### Fixed

- A keep-alive connection that receives a partial request now uses the header
  deadline instead of the full idle deadline, and a parked response cancels
  the idle deadline so a long delay cannot be reaped mid-flight.
- A timing-wheel callback that cancels a sibling in the same slot, re-arms the
  dispatching node, or schedules during cascade is handled without double
  delivery or list corruption.
- The client parser no longer rescans the accumulated response prefix on
  every read; byte-at-a-time delivery is linear in the wire size.
- A full indexed rate-limit table no longer scans every bucket to find the
  oldest key; an evicted key still starts with zero tokens.
- `client(N).init` initializes every slot's lifecycle state. A setup failure
  before the first fetch can no longer make `deinit` observe an undefined
  `active` flag and abort.
- Pub/sub fan-out no longer visits every global subscription row, and topic id
  reuse cannot misdeliver to a subscriber of another topic.

### Security

- XEV-001 remains the only downstream libxev patch and is now an auditable
  fork commit rather than an unversioned source overlay. The Windows native
  AcceptEx re-arm regression remains the release gate for that commit.
- Indexed rate limiting bounds probe work after eviction churn and preserves
  the fail-closed empty-table behavior.
- Topic and subscription indexes fail closed when capacity is exhausted; no
  new allocation, lock, or cross-thread state enters the publish path.

### Limits

- The v2.0.0 quiet-host performance evidence (2.1-C1), receive-side UDP GRO
  (2.1-C2), cross-process listener handoff (2.1-C4), and optional API
  follow-ups (2.1-C5) are carried to 2.2.0 and later; see `TODO.md`.
- The native Windows runtime job compiles the full tree and runs XEV-001 and
  XEV-002, but it is not green as of 2026-10-24: the Windows cross-target
  compile gate passes while the runtime suite still reports client connect
  mapping, one timer assertion, the static-file `std.Io` positional read, and
  three TLS cluster handshake failures. Windows remains compile-only; the raw
  run and remaining test list are carried in `TODO.md` 2.2-C4.

## [2.0.6] - 2026-10-23

Patch release that makes the source package self-contained for downstream
consumers and lets the linker discard unused vendor functions. Public APIs, C
ABI layouts, route capacities, runtime behavior, and wire formats are unchanged.

### Added

- `scripts/check_package_paths.sh` archives the tracked tree, fetches it with
  `zig fetch` so the package manager applies `build.zig.zon` `.paths`, and
  compiles the downstream package consumer from that copy. The Test and Publish
  workflows run it, so a path omitted from the package fails before a release
  instead of during a downstream fetch.

### Changed

- `build.zig.zon` includes `vendor/libxev_overlay` in `.paths`. A clean
  `zig fetch` now carries the auditable IOCP accept overlay, so a downstream
  build no longer fails its first cache check with
  `vendor/libxev_overlay/src/backend/iocp.zig` `FileNotFound`.
- BoringSSL, lsquic, libdeflate, and zlib compile with
  `-ffunction-sections` and `-fdata-sections`. The existing `--gc-sections`
  link can then discard unused functions inside objects pulled in for another
  symbol. The flags change code layout only; no source, wire byte, or protocol
  path moves.
- The Publish workflow creates a GitHub release only when the pushed tag equals
  `v` plus the `build.zig.zon` version. Downstream pin tags still run the full
  compliance and verification jobs, but no longer fail release creation for a
  missing changelog section. A plain `vX.Y.Z` tag that does not match the
  manifest fails the metadata check.

### Security

- No security-relevant behavior changed.

## [2.0.5] - 2026-10-22

Patch release that refreshes the pinned C dependencies for the QPACK
decoded-header amplification class, closes transport liveness defects, and
tightens WebSocket and HTTP/3 field validation. Public APIs, C ABI layouts,
route capacities, and default limits are unchanged.

### Changed

- BoringSSL advances to release `0.20261020.0`
  (`d3bf4795ad5b79d646cddf2fec687da5b9b502db`), lsquic to `v4.10.2`
  (`a9616720af78b9aab895145c1792d5305c480ae8`), and ls-hpack to
  `fda48e02491d865cce00612be8cc10c2622b8e55`. The ls-hpack delta is
  CMake-only. ls-qpack, libdeflate, zlib, and libxev remain at their current
  pins; libxev `9ce8e8e` is the last revision compatible with Zig 0.16.0.
- `build.zig.zon.{json,nix,txt}` and the recorded Nix hashes are regenerated.
  `scripts/update_zon_files.sh` now accepts both the legacy single-`TMPDIR`
  and current per-package zon2nix layouts.
- `vendor/lsquic_overlay` is regenerated from the v4.10.2 tree and
  `patches/lsquic_h3_message_error.patch`, so the stream-scoped header-error
  behavior is preserved on the new release.
- HTTP/3 activation (`listen_udp`) rejects `max_header_size` above 65535
  because lsxpack field lengths are 16-bit. The shared HTTP/1.1 and HTTP/2
  limit is unchanged and may still be raised above that value.

### Fixed

- Plaintext HTTP/1 static-file responses take file ownership before writing the
  response head. The Linux direct-send path can no longer finish the head
  without arming the completion that pumps the body, which previously left the
  body unsent and held the connection slot until the idle timeout.
- WebSocket upgrades read `Connection`, `Upgrade`, `Sec-WebSocket-Version`,
  `Sec-WebSocket-Key`, and `Sec-WebSocket-Extensions` through the complete
  request header view, including the extra slots used when
  `max_header_count` exceeds the inline capacity. A duplicate key in those
  slots is now rejected instead of being treated as absent.
- HTTP/3 engine initialization rejects request header storage above the `u16`
  lsxpack representation instead of trapping or truncating at the first
  decoded field. The check runs before any QUIC slab is allocated.
- A decoded HTTP/3 header section that exceeds the configured storage is
  rejected with a stream-scoped `H3_MESSAGE_ERROR` rather than aborting every
  request on the connection.
- A direct batch flush that empties the write ring now settles WebSocket
  backpressure at the batch boundary, so a paused producer is resumed even
  when no write completion runs.
- kqueue cancellation now flushes queued completions before canceling, so the
  target callback owns its flag and a closed slot cannot return to the pool
  before its read, write, and close completions drain. TCP, UDP, and client
  teardown use the same submit-before-cancel rule as IOCP.
- A timer tick that re-arms its own timer no longer queues the completion a
  second time.
- Repeated accept failures now arm a bounded one-shot retry instead of
  returning `.rearm` immediately. A full descriptor table costs one accept
  attempt per second instead of a busy loop and a warning flood.
- The HTTP/1 parser keeps a monotonic delimiter scan cursor across reads.
  Dribbled request lines, header blocks, chunk sizes, chunk extensions, and
  trailers are scanned once instead of rescanning the accumulated prefix.
- Rate-limit tables built empty use an open-addressed home probe, so established
  keys and new keys with free capacity are found without a full-table scan.
  Pre-seeded tables keep the exact legacy scan and eviction order.
- Pub/sub publish holds a publish-depth frame and tombstones reentrant
  unsubscribes until the outermost fan-out returns. A failed subscriber can no
  longer shift rows, remap topic ids, or cause cross-topic delivery.
- Pattern-only routers skip the static-route hash and its empty probe table.

### Security

- lsquic `v4.10.2` contains the QPACK decoded-header-set bound introduced in
  `v4.9.0` and the follow-up header, parser, and allocation fixes through
  October 2026. The issue is described in "Header Accordions: QPACK
  amplification attacks against HTTP/3 servers"
  (https://foxio.io/blog/header-accordions-qpack-amplification-attacks-against-http-3-servers):
  repeated QPACK references could expand a small HEADERS frame into a much
  larger retained header set. Upstream fixed lsquic in `v4.9.0` without a CVE;
  this release moves the pin from `v4.10.0` to the tagged `v4.10.2` release.
  The server already advertises a bounded field section, disables the QPACK
  dynamic table, caps buffered header sets, and rejects an over-limit decoded
  section on the request stream instead of the connection.
- WebSocket upgrade validation no longer misses duplicate security-sensitive
  fields that arrive in the extra header slots.

## [2.0.0] - 2026-10-20

This release removes write-syscall amplification, batches WebSocket echoes,
moves compression codecs to worker startup, adds a deterministic multi-port
listener barrier, and completes the ordinary HTTP method surface with TRACE. The
cluster API and C struct layouts are unchanged; the only C enum addition is
append-only. No performance number is claimed without a quiet-host rerun.

### Added

- `listen_all` binds up to four TCP endpoints, verifies every local port, and
  only then arms all accept completions. A failed bind closes the sockets
  created by that call and leaves routes unlocked. Endpoints may select TLS
  independently while sharing the application certificate. Listener port
  verification reads both IPv4 and IPv6 socket addresses.
- `ClusterOptions.worker_count` selects an explicit active count, and
  `build_cluster_from_environment` resolves `UWEBZOCKETS_WORKERS` or the
  platform CPU count at startup. Only active workers allocate slabs, inboxes,
  and thread handles. The `examples/tls_cluster.zig` runner accepts the
  canonical variable and keeps `UWZ_WORKERS` as a compatibility alias.
- Per-worker HTTP gzip pooling: `with_http_compression(true)` opens one
  `libdeflate` compressor and bounded scratch during startup, and
  `Response.end_gzip` compresses HTTP/1.1 and HTTP/2 responses without a
  request-path allocation. `compression_pool.Pool` is exported for direct use.
- Opt-in TRACE support across `HttpMethod`, `Router.trace`, `App.trace`, the
  client `Method`, C ABI `UWZ_HTTP_TRACE = 9`, HTTP/2, OpenAPI, and the HTTP/3
  replay-safety classifier. TRACE is admitted as TLS 0-RTT-safe; no automatic
  route or RFC 9110 echo response is synthesized.
- Linux UDP transmit batching: equal-sized lsquic packets for one destination
  use one `sendmsg` with `UDP_SEGMENT` (GSO), with a per-packet fallback for
  mixed sizes, unsupported kernels, and non-Linux targets.
- Regression coverage for TRACE parsing and dispatch, 0-RTT classification,
  pipelined write batching, WebSocket SIMD equivalence, startup compressor
  pooling, multi-listener binding, per-listener TLS selection, runtime worker
  counts, TCP flags, and loopback GSO delivery.

### Changed

- HTTP/1.1 reads that contain more than one complete request now append every
  response to the bounded write ring and flush once. A lone request keeps the
  direct nonblocking `sendmsg` fast path.
- Consecutive WebSocket frames from one read completion share one write flush.
  Unmasking uses a 256-bit vector on AVX2 targets and keeps the 128-bit
  SSE2/NEON baseline with a scalar tail.
- `ServerConfig.http_compression` and `Server.builder(...).with_http_compression`
  opt into the HTTP gzip pool. The existing RFC 7692 `compression` switch and
  scratch planning are unchanged.
- `Cluster.worker(index)` and every cluster loop operate on the active worker
  slice, so a large compiled capacity no longer reserves memory for unused
  inboxes.
- The TLS cluster example dispatches the runtime worker count instead of a
  fixed 1/2/4/8 switch, and `tls-single` defaults to one worker when no override
  is set.

### Fixed

- HTTP/2 WebSocket tunnel setup no longer reads an uninitialized `WebSocket`
  slot before the first upgrade. A reused pooled connection or an optimized
  build could otherwise treat the tunnel as capacity-reached and skip the
  handshake.
- Pipelined plaintext responses no longer issue one write syscall per response
  when the read already contains another complete request. If the accumulated
  batch would overflow the ring, the completed batch is drained before the next
  response is admitted instead of disconnecting mid-pipeline.
- A direct batch flush skips streaming producer connections and leaves file
  bodies on the completion path, so a drained socket still resumes the producer
  or file pump.
- IPv6 listener port verification uses a family-sized socket-address buffer, so
  `listen_all` does not regress `App.listen("::", ...)` on Windows.
- WebSocket echo paths no longer arm a completion per buffered frame.
- Startup with auxiliary listeners can no longer race the primary port into
  accepting before later sockets are bound.
- HTTP response compression no longer allocates a codec when an application
  opts into the startup pool.

### Security

- TRACE is opt-in and documented as a cross-site tracing risk. The library does
  not synthesize the RFC 9110 echo response; any application echo must redact
  `Authorization`, `Cookie`, `Proxy-Authorization`, and application secrets and
  bound the reflected bytes to the response capacity.
- TRACE joins `GET`, `HEAD`, and `OPTIONS` in the TLS 0-RTT safe-method
  allowlist. `QUERY` remains replay-unsafe and still receives `425 Too Early`
  during early data.
- HTTP gzip is opt-in. Do not compress responses that mix secrets with
  attacker-controlled input.
- No C ABI enum value was renumbered; `UWZ_HTTP_TRACE = 9` is appended after
  `UWZ_HTTP_QUERY = 8`. CONNECT remains internal and is not exposed through the
  application or C route APIs.

### Limits

- The pipelined-throughput, WebSocket-echo, and `json-comp` targets in the v2.0
  checklist require the designated quiet host. Implementation and unit gates
  landed, but no number is published from a shared or unrecorded run. The rerun
  is carried into the 2.1.0 evidence track.
- UDP receive-side `UDP_GRO` is disabled: the libxev UDP completion does not
  expose ancillary segment boundaries, so a coalesced buffer would be parsed as
  one datagram. Transmit GSO is enabled and tested.
- `listen_all` is an in-process all-or-nothing barrier. Cross-process socket
  takeover remains scheduled for the v2.9.0 drain milestone.
- The libxev IOCP accept overlay and pin are unchanged while upstream issue
  #252 remains open. No dependency pin was moved in this release.
- Windows support still depends on the native runtime job being green for the
  release commit; this release does not publish Windows binaries.

## [1.9.0] - 2026-10-20

This release closes or re-declares every limit from the v1.8.5/v1.8.9
declared-limits handoff. The HTTP/2-over-TLS contract now has a full
64-2,048-connection characterization with raw artifacts; the Windows IOCP
accept and queued-close blockers have auditable fixes and a native runtime job;
and the remaining TLS, sanitizer, and backend boundaries are dated decisions
with restoration criteria. No exported Zig or C API signature changes.

### Added

- `h2-tls-scaling-v1` evidence from the repository host: a 4-worker TLS
  cluster completed 30 of 30 samples with zero failed, errored, timed-out, or
  non-2xx requests at 64 through 2,048 connections, reaching a median
  276,534.80 requests/s at 1,024 connections with one stream and 669,300.80 with
  eight. The plaintext control, single-application TLS control, 1/2/4-worker
  comparison, CPU/RSS samples, per-worker accepts, host metadata, and the
  filled hypothesis table are under
  `benchmarks/results/h2_tls_scaling_v1/2026_10_19/`.
- `UWZ_MODE` controls in `examples/tls_cluster.zig`: `tls-cluster`,
  `plaintext-cluster`, and `tls-single`. Cluster modes publish one
  `worker_accepts` line per worker after shutdown, and the single mode always
  requires PEM files.
- Benchmark runner evidence capture: optional URL argument, real-credential
  preflight, capacity and open-file checks, CPU/RSS sampling, backend detection,
  per-worker accepts, parsed request percentiles, failure snapshots, and
  snake_case artifact names. The readiness probe now requires one successful
  request because h2load exits zero even when every connection fails.
- `scripts/probe_tls_resumption.sh`, an explicit-ticket TLS 1.3 resumption
  probe. It measured 20 new/100 reused handshakes on one worker and 97 new/23
  reused on four workers, confirming that per-worker ticket keys bound reuse to
  the issuing worker.
- Native `windows-2025` runtime job in `windows.yml` beside the compile and
  static-library gates.
- [ADR 0003](docs/adr/0003-tls-cluster-operational-boundaries.md): no credential
  hot reload in 1.9.0, rolling restart remains supported, and cross-worker
  session resumption is a measured, accepted boundary.
- [ADR 0004](docs/adr/0004-windows-iocp-accept-and-queued-close.md): auditable
  libxev IOCP accept overlay and submit-before-cancel close policy.
- Regression tests for queued-write close releasing its pool slot, HTTP/2
  stream-capacity refusal without GOAWAY, connection credit stacking above
  per-stream allowances, per-stream credit isolation, and
  `Cluster.request_shutdown` after `deinit`.
- Clean-clone provenance for `v1.8.9`: tag, commit
  `2573661d12e573d00ed0036736a68d34955c1339`, Zig 0.16.0, contract
  `h2-tls-scaling-v1`, and a green `zig build test --summary all` from an empty
  Zig cache, archived with the measurement artifacts.

### Changed

- `Cluster.request_shutdown` now returns immediately after `deinit` and
  documents the no-op on the method itself. The behavior stays docs-only; no
  public lifecycle getter was added.
- Windows close now submits queued IOCP completions before canceling them, so a
  completion canceled in the callback that queued it still delivers its target
  callback and clears `read_active`/`is_writing`.
- The pinned libxev sources are copied into the build graph and one
  pre-generated IOCP file is overlaid. `scripts/check_vendor_overlay.sh`
  verifies both the libxev and lsquic overlays against their pinned sources and
  audit patches; the Zig package cache is never modified.
- `benchmarks/h2_tls_scaling_v1.env` quotes the connection and stream lists so
  a POSIX shell can source it. The measurement parameters are unchanged.
- The MemorySanitizer contract is permanently documented as a
  dependency-boundary smoke dated 2026-10-19, because Zig 0.16 emits no MSan
  instrumentation and a second instrumented BoringSSL toolchain is out of
  scope.
- Documentation now records the measured H2/TLS status, the Windows runtime
  job, the permanent MSan contract, the backend-stickiness decision, and the
  dated rotation/resumption boundaries.

### Fixed

- Windows IOCP accept: `internal_accept_socket` is cleared after `AcceptEx`
  transfers the socket and on both error paths, so a persistent accept loop no
  longer calls `AcceptEx` on an already-connected socket and panics on
  `WSAEINVAL`.
- Windows close: a read or write canceled before submission no longer strands
  the connection slot and turns shutdown into `ShutdownIncomplete`.
- The H2/TLS runner no longer treats a failed h2load readiness request as
  success, no longer aborts on its own summary format, and no longer writes
  filenames that violate the repository convention.

### Security

- No authentication, TLS policy, or request-path surface changed. The Windows
  overlay is limited to clearing a socket handle; the transport change only
  reorders submission before cancellation.
- Recorded TLS measurements used a local CA-signed PEM leaf, not
  `enable_https_ephemeral`; the private key lived only under `/dev/shm` and was
  never committed.
- Credential rotation still requires a rolling restart. This is now a dated
  decision with an explicit restoration criterion rather than an open omission.

### Limits

- HttpArena `baseline-h2` remains withdrawn. Restoring it requires an adapter PR
  in `MDA2AV/HttpArena` that uses only the public cluster API, a released tag
  from a clean dependency cache, and an official
  `/benchmark -f uwebzockets --save` run with fresh nonzero 256/1,024 rows.
- The H2/TLS numbers are local characterization on a shared host with the
  `powersave` governor, not a quiet-host or HttpArena claim. The historical
  zero-requests single-app failure did not reproduce; the control served
  82,136.60 requests/s at 1,024 connections with one stream.
- Windows is not promoted in the support claim until the native runtime job is
  green for the release commit. No Windows binaries are published.
- `h2-tls-scaling-v1` stays out of `benchmark.yml` while runners are shared. A
  dedicated quiet runner may add a non-gating `workflow_dispatch` job that
  uploads raw artifacts and never compares with shared-runner numbers.
- The v1.9.0 tag is maintainer-owned after review and merge. Agents did not
  create, move, or push any tag.
- mTLS and QUIC/HTTP/3 clustering remain documented boundaries; no new promise
  is made for them in this release.

## [1.8.9] - 2026-10-19

This release resolves the v1.8.5 declared-limits handoff. The io_uring retry
policy is now a pure, tested decision function; threaded tests, including the
cluster TLS lifecycle tests, run under the address sanitizer instead of
skipping; the cluster test plumbing reads listener ports and receive timeouts
through Winsock on Windows; and `h2-tls-scaling-v1` fixes the HTTP/2-over-TLS
characterization contract and runner. No exported Zig or C API changes. The
release number follows the maintainer's declared-limits plan: the
semver-minimal number after 1.8.5 would have been 1.8.6, and this deviation is
recorded here.

### Added

- Pure io_uring loop-creation retry policy (`RingRetryDecision`,
  `ring_retry_decision`) with deterministic tests for the transient
  `error.SystemResources` case, the terminal error case, a non-io_uring
  backend, and the `ring_init_attempts` bound. `src/core/loop.zig` keeps the
  syscall and sleep in the thin wrapper, and the established backend still
  never switches.
- `h2-tls-scaling-v1` measurement contract
  (`benchmarks/h2_tls_scaling_guarantee.md`,
  `benchmarks/h2_tls_scaling_v1.env`, `scripts/benchmark_h2_tls.sh`). The
  contract pins the generator, connection and stream levels, duration, warmup,
  samples, statistic, exact request and response bytes, success definition,
  and the single-application, plaintext-cluster, and TLS-cluster controls.
  `http-throughput-v1` is untouched.
- `tls_cluster` environment overrides for PEM credentials, bind address, port,
  worker count, and connection capacity so the benchmark contract can run a
  real-credential ReleaseFast cluster without adapter-side setup.
- `TCP.listener_port` and `TCP.set_receive_timeout` platform helpers: the
  Windows branches bind `ws2_32.getsockname` and `ws2_32.setsockopt`
  `SO_RCVTIMEO` through the same extern pattern as the listener.

### Changed

- Threaded tests no longer skip sanitizer graphs: the TLS cluster handshake,
  shared-port, and ALPN tests, the client loopback and TLS server tests, the
  router cross-thread shutdown test, the cluster queue producer test, and the
  affinity probe all execute under ASan. Sanitizer runs set
  `use_sigaltstack=0`, because ASan's thread teardown unmaps whichever
  alternate signal stack is installed and Zig's thread-local stack is not page
  aligned; leak detection, `halt_on_error`, and every assertion stay in place.
- The shared-port cluster TLS test retries up to eight fresh loopback port
  reservations instead of two, so a stolen ephemeral port cannot turn a
  transient race into a flake.
- The Windows cluster TLS tests no longer return `error.WorkerPortUnsupported`;
  the compile gate now covers the same port lookup and receive timeout paths
  the Linux tests use.

### Fixed

- The ASan and UBSan test graph previously crashed at thread teardown with
  `AddressSanitizer failed to deallocate ... (error code: 22)` because Zig's
  thread-local alternate signal stack is not page aligned. Sanitizer runs now
  set `use_sigaltstack=0`, leaving leak detection and every other check on.

### Security

- No security-sensitive behavior changed. The Windows test helpers only add
  the missing `getsockname` and `SO_RCVTIMEO` bindings used by tests.

### Limits

- The 256- and 1,024-connection `h2-tls-scaling-v1` rows and the HttpArena
  `baseline-h2` restoration remain maintainer measurement tasks: they need a
  quiet host, a released tag, and the external adapter repository. The
  contract, runner, and real-credential example land here; no measured result
  is claimed.
- Windows runtime coverage stays compile-only. The two defects recorded in
  [docs/roadmap.md](docs/roadmap.md#windows-runtime-blocker-details) - the
  pinned libxev IOCP accept-socket reuse and the queued-completion close path -
  still block the first native accept loop, so no runtime job is added and no
  Windows binaries are published.

## [1.8.5] - 2026-10-18

This release adds a supported TLS-enabled TCP cluster so HTTP/1.1 and HTTP/2
over TLS can use the shared-nothing worker model that plaintext clusters
already use, and fixes event-loop backend selection so multi-loop processes
cannot mix epoll and io_uring loops. Single-application TLS constructors,
existing cluster signatures, wire behavior, and default capacity semantics are
unchanged.

### Added

- TLS-enabled TCP clusters: `Cluster.enable_https` and
  `Cluster.enable_https_ephemeral` load or generate one private BoringSSL
  context per worker before `listen`. ALPN keeps advertising `h2` ahead of
  `http/1.1`, every connection creates its own `SSL` from its worker's
  context, and no TLS state is shared between loops. A failed enable releases
  exactly the contexts it created and is retryable; a repeated enable,
  enable-after-listen, and enable on a running or released cluster report
  named errors. QUIC/HTTP/3 clustering remains out of scope.
- `tls_cluster` example and cluster TLS lifecycle, rollback, multi-worker
  handshake, shared-port, and HTTP/2 ALPN regression tests.

### Changed

- Event loop backend selection (`src/core/loop.zig`) now runs exactly once per
  process. libxev dispatches every loop operation through one process-global
  backend tag, so later loops reuse the established selection instead of
  re-probing and potentially creating a mixed epoll/io_uring group. The
  io_uring-to-epoll fallback remains available while the first loop is
  created; a backend changed after selection fails cleanly with
  `error.BackendChanged`.
- Additional io_uring loop creation retries the same backend briefly while the
  kernel uncharges a closed ring, instead of changing the process backend
  under existing loops.

### Fixed

- `Cluster.listen` on a released cluster silently succeeded without binding
  any worker; it now reports `error.ClusterDeinitialized`.

## [1.8.0] - 2026-10-06

This release removes per-response formatting overhead, gives the transport a
zero-copy plaintext fast path and Nagle-free accepts, indexes exact routes
ahead of the radix walk, and makes the event loop select its libxev backend at
runtime so Linux containers without io_uring still start. No exported function
signature, wire behavior, or default capacity semantic changes.

### Added

- Runtime-selectable libxev backend (`src/core/xev.zig`): the loop probes
  io_uring and degrades to epoll when the kernel or a container seccomp policy
  rejects the ring, so Docker Desktop and OrbStack hosts no longer need
  privileges just to start. epoll loops own a small thread pool for blocking
  file operations; io_uring loops do not.
- Fixed-capacity FNV-1a index for exact static routes (`src/router/radix.zig`):
  lookups verify the candidate's stored segments byte-for-byte, so a hash
  collision falls through to the radix walk instead of selecting the wrong
  route.
- Allocation-free HTTP/1.1 head writer (`status.format_http1_framing`,
  `status.format_http1_chunked_framing`) with an exact-bounds decimal encoder.
- `TCP_NODELAY` is requested on every accepted connection, removing the
  Nagle/delayed-ACK stall from small responses.

### Changed

- Router: exact static routes now resolve through an open-addressed FNV-1a
  hash index before the radix walk. Capacities, matching order, and error
  behavior are unchanged; the default router storage region grows by 5,632
  bytes (512 hash slots, 512 node slots, 256 parent links).
- HTTP/1.1 response heads, `append_header`, and `redirect` write bytes with
  manual copies instead of `std.fmt`, removing format machinery from the
  per-response path. Ordering, validation, and emitted bytes are unchanged.
- Plaintext responses are sent with a single nonblocking `sendmsg` when the
  write ring is empty and no write is in flight; a partial send queues only
  the unsent suffix, so any remaining queue copy carries new bytes.
- The Linux development file watcher polls the inotify descriptor and drains
  it with direct nonblocking reads, so it no longer depends on a thread-pool
  read completion.
- `TcpConnection.begin_file_response` uses the shared framing writer.

### Fixed

- epoll: canceling an armed read or write removes the registration without
  invoking the canceled callback, so the close callback now clears the flags
  that completion would have cleared. Without this, closed slots never
  returned to the pool on the epoll fallback.
- The event loop shuts its owned thread pool down before releasing loop
  storage, matching libxev's teardown ordering.

### Security

- Response field and redirect formatters bound every slice before
  concatenation, closing an integer-overflow path in the length computation.

## [1.7.1] - 2026-10-06

This release fixes the defects found by a full-tree audit of 1.7.0. It closes a
remote HTTP/3 resource-exhaustion vector, several lifetime and error-path bugs,
RFC compliance gaps in HTTP/1.1, HTTP/2, and RFC 8441 WebSockets, and TLS
policy issues. Every behavior change is a fail-closed correction or a truthful
capability report; no default capacity, wire format, or exported function
signature changes.

### Fixed

- HTTP/3: a field-level header rejection leaked one engine header set and one
  lsquic hblock context per malformed request; after `2 * capacity` malformed
  requests the listener aborted every subsequent connection, including new
  ones. The decoder now releases the in-flight set before resetting the
  stream, and header-pool exhaustion resets only the affected stream with
  `H3_REQUEST_REJECTED` instead of aborting the connection.
- WebSocket over HTTP/2: a failed send could escalate into tearing down the
  whole HTTP/2 connection, because `terminate` stopped recognizing the tunnel
  after deinit and fell through to the TCP close path. Termination is now
  idempotent and the transport is captured before any callback can deinit the
  socket. A tunnel also becomes live only after the `200` commits, so a failed
  setup cannot fire `close` without a preceding `open`.
- TLS: `init_mtls` in `optional` and `required` modes now disables TLS 1.3
  early data; the client certificate is not verified until the second flight,
  so early data could reach a route under a revoked or missing certificate.
- Client: the outbound TLS context pins TLS 1.3 as both the minimum and maximum
  protocol version instead of inheriting BoringSSL's TLS 1.2-1.3 default.
- App lifecycle: a failed observability install no longer leaks the idle
  sweeper timer from `listen`, `listen_udp` no longer deinits a started QUIC
  transport on a later failure, and cluster workers install the metrics route.
- HTTP/1.1: `OPTIONS *` (asterisk-form) and `http`/`https` absolute-form
  request targets are accepted per RFC 9112; a `Transfer-Encoding` /
  `Content-Length` conflict reports `400` even when the Content-Length exceeds
  the body limit; `HttpParser.consume` reports a stable consumed prefix when a
  completed request is re-entered.
- HTTP/2: a HEADERS frame that opens an id below the peer high-water mark it
  never opened is a connection `PROTOCOL_ERROR` (h2spec 5.1.1) instead of a
  stream reset; PRIORITY self-dependency is a stream error; SETTINGS advertises
  the configured HPACK dynamic-table capacity; control bytes are rejected in
  field values and `:path`; `Response.begin_stream` carries pending headers on
  HTTP/2 and HTTP/3.
- WebSocket compression: an outgoing compressed message whose compressed form
  exceeds the frame limit falls back to an uncompressed frame when the raw
  payload fits (RFC 7692 allows this), instead of failing a legal message.
- Requests: `schema` validation fails closed at the nesting-depth cap instead
  of silently skipping deeper rules; multipart accepts an RFC 2046 preamble and
  epilogue; static files honor `If-None-Match` lists, weak validators, and
  `*`, and require a matching `If-Range` validator before serving a range.
- Crypto: a failed HMAC call is caught by a written unreachable proof instead
  of silently hashing an uninitialized digest, and AES-GCM seal failures after
  exhaustive size checks report `error.SealFailed` instead of mislabeling an
  internal BoringSSL failure as a caller sizing mistake.
- XDP: a `kernel_bypass` request reports `.standard` with reason
  `.data_path_unwired` and increments the fallback counter instead of claiming
  an active bypass the server data path never uses.
- Datagram ring: non-power-of-two capacities stay correct across the u32
  cursor ceiling by rebasing both cursors by one capacity before wrap, with a
  proof that such cursors never wrap a second time.
- OSS-Fuzz: libFuzzer objects carry inline-8bit-counter coverage (registered
  with the engine by `oss-fuzz/zig_sancov_shim.c`) and the build fails when the
  counter sections are missing; HPACK and multipart parsing
  gained deterministic fuzz coverage; WASM and eBPF artifacts are compiled in
  CI.

### Changed

- Route registration rejects parameterized patterns whose segment skeleton
  differs only in capture names with `error.RoutePatternConflicts`; previously
  the later pattern was silently unreachable.
- Cross-thread shutdown uses the new `App.request_shutdown`; `App.shutdown` is
  documented loop-thread only. `App.run` owns a wakeup async on every target so
  the request reaches the owning loop.
- `ServerConfig.max_h3_response_header_count` is capped at 4096 so QUIC
  response framing cannot size a multi-megabyte stack frame.
- `AesGcmError` gains `SealFailed` for residual seal failures that the size
  prechecks cannot explain.
- BoringSSL is re-pinned to `dd73e69a4e86fa178a4d19033c691e9b42cc1088`; zslay,
  libxev, lsquic, ls-qpack, ls-hpack, libdeflate, and zlib already track their
  latest published revisions. The Nix flake inputs (`nixpkgs`, `flake-parts`,
  `zig-overlay`, and `zon2nix`) are updated and `build.zig.zon.nix`, `.json`,
  and `.txt` are regenerated in lockstep.
- Publishing no longer builds or uploads per-platform static-library archives.
  A release is the tagged source: consumers use `zig fetch` and their own
  toolchain builds the pinned dependencies.
- Windows is documented as not officially supported. The reusable workflow
  remains a compile-only check, and the pinned libxev IOCP accept lifecycle
  remains the runtime blocker.
- Docs: mTLS 0-RTT, CRL enforcement, the TLS 1.3 client pin, the App write
  queue default, the RFC 8441 key rule, and the AF_XDP status now match the
  implementation.

## [1.7.0] - 2026-09-26

This release closes the client/server and production-hardening boundaries. It
adds a bounded HTTP/1.1 client, mutual TLS, authentication and rate-limiting
middleware, graceful signal-driven shutdown, HTTP/2 and HTTP/3 observability,
and a native Windows test run, and it restructures the developer documentation
into per-protocol and per-task guides. Every change is additive: 1.6.x
applications recompile and behave unchanged.

### Added

- Client: `uz.client` is a bounded HTTP/1.1 client over TCP and TLS.
  `client(max_inflight)` owns a libxev loop and fixed request slots;
  `fetch_blocking` runs one request on a temporary client and copies the
  response into caller-owned `FetchStorage`. `Method`, `Header`, `Request`,
  `TlsOptions`, `FetchOptions`, `ResponseView`, `Failure`, `FetchOutcome`, and
  `FetchCallback` are the named public types. Plaintext steady state allocates
  nothing; TLS allocates its BoringSSL session once per connection. Trust fails
  closed: `verify = true` requires a CA path, SNI and hostname/IP verification
  are enforced, and mixing trust policies on one client is rejected. Responses
  support `Content-Length`, chunked coding with trailers, close-delimited
  bodies, and bounded 1xx handling. HTTP/2 and HTTP/3 clients are deliberately
  not provided.
- mTLS: `tls.ClientAuth`, `tls.ClientAuthConfig`, `TlsContext.init_mtls`, and
  `App.init_https_mtls` verify client certificates against a caller CA bundle.
  `none`, `optional`, and `required` modes cover the three handshake policies;
  `required` fails closed when a certificate is missing, and a bad bundle fails
  context creation instead of degrading silently.
- Authentication: `middleware.Auth` and `middleware.auth` validate Basic and
  Bearer credentials over caller-owned lists with a bounded stack decode,
  constant-time comparison, duplicate `Authorization` rejection, and
  `WWW-Authenticate` challenges listing only the configured schemes.
- Rate limiting: `middleware.RateLimit` and `middleware.rate_limit` charge
  caller-owned token buckets keyed by a custom function, an FNV-1a hashed
  header, or a constant, refill continuously from the monotonic clock, and
  answer an empty bucket with `429 Too Many Requests` and `Retry-After`.
  `middleware.rate_limit_step`, `middleware.RateLimitDecision`, and
  `middleware.fnv1a_64` expose the pure token math and key hash.
- Shutdown: `App.catch_shutdown_signals` and `Cluster.catch_shutdown_signals`
  install one process-wide SIGINT/SIGTERM watcher (a Windows console control
  handler on Windows) that drains through the normal shutdown path. The
  internal `src/core/signal.zig` uses a POSIX self-pipe or a Windows async
  wakeup, coalesces repeated signals, and fails closed if the watch breaks.
- Observability: HTTP/2 dispatch emits one `http_request` development-log
  record per completed exchange and advances `uwz_http_requests`; HTTP/3 emits
  one record per completed exchange through the owning thread's sink; WebSocket
  upgrades record their `101` or HTTP/2 `200` response.
- Documentation: new [getting started](docs/getting_started.md),
  [API](docs/api.md), [deployment](docs/deployment.md),
  [roadmap](docs/roadmap.md), [troubleshooting](docs/troubleshooting.md), and
  [client](docs/client.md) guides; the protocol documentation is split into
  [HTTP](docs/http.md), [HTTP/2](docs/http2.md), [HTTP/3](docs/quic.md),
  [WebSocket](docs/websocket.md), and [JSON-RPC](docs/json_rpc.md) documents.
- CI: `scripts/check_docs.sh` validates every relative markdown link in the
  lint job. Windows remains a compile-verified Tier 2 target: a native runtime
  gate is blocked by two accept-loop defects (one in the pinned libxev IOCP
  backend, one in the Windows close path), recorded in
  [docs/roadmap.md](docs/roadmap.md#windows-runtime-blocker-details).

### Changed

- `SECURITY.md` supported versions now track the latest released minor line
  instead of a stale fixed version.
- HTTP/3 request records and the HTTP/2 WebSocket tunnel record are additive
  log output; no wire behavior changed.
- `App.init_https_mtls` joins the existing `init_https` family without changing
  any existing signature, default, or ALPN/0-RTT policy.

### Security

- Rate limiting fails closed: an evicted bucket starts empty so rotating an
  attacker-controlled key cannot reset a budget, refill math is clamped against
  overflow at extreme rates and idle gaps, and a zero rate omits `Retry-After`
  because no retry can arrive.
- Client TLS verification cannot be silently bypassed: `verify = true` without
  a trust store is an error, hostname and IP verification are applied per
  session, and one client refuses to reuse a context under different trust
  rules.
- The graceful-shutdown watcher fails closed: an unexpected poll failure
  requests shutdown rather than silently dropping later signals.
- The client abandons in-flight slots after a terminal loop failure so
  teardown never delivers a callback into a stopped loop.

## [1.6.0] - 2026-09-26

This release adds a vectorized, zero-copy parser for `Cookie` request fields.
`cookie.CookieJar` materializes up to 32 pairs into a fixed struct-of-arrays
view that borrows the original header bytes, so lookups run with no allocation
and no copies on the request path. The existing scalar `cookie.iterator` and
`cookie.find` helpers are unchanged.

### Added

- `cookie.CookieJar`, `cookie.CookieJarOf(capacity)`, and `cookie.max_cookies`:
  parse a raw `Cookie` field with a one-pass `@Vector` scan for `=` and `;`
  boundaries and store borrowed name/value slices in a fixed struct of arrays
  (`at`, `get`, `has`, `pairs`). Malformed pairs are skipped and pairs beyond
  the capacity are ignored instead of rejected.
- `simd.index_of_either_byte`: vectorized first-occurrence scan for either of
  two bytes, used by the cookie parser to find both delimiters in one pass.
- `fuzz/cookie_parse.zig` OSS-Fuzz entrypoint plus deterministic Smith coverage
  in `src/tests/fuzz_main.zig`: both assert that borrowed slices stay inside the
  parsed input and that the jar agrees with the scalar iterator prefix.

## [1.5.0] - 2026-09-26

This release makes local TLS setup a one-liner. When no certificate files are
available, `App.init_https_ephemeral` and `App.init_http3_ephemeral` generate
an ECDSA P-256 key and a self-signed localhost certificate in memory with
BoringSSL, so development and test servers start over HTTPS with no `openssl`
commands, no files, and no configuration. Production paths are unchanged and
still load real PEM files through `init_https` and `init_http3`.

### Added

- In-memory ephemeral TLS credentials: `TlsContext.init_ephemeral` and
  `TlsContext.init_http3_ephemeral` generate an ECDSA P-256 key and a
  self-signed X.509 certificate covering `localhost`, `127.0.0.1`, and `::1`.
  Nothing is written to disk.
- `App.init_https_ephemeral` and `App.init_http3_ephemeral` start HTTPS and
  dual HTTPS/HTTP/3 applications from those credentials with one call.
- `tls.CertificateNames` overrides the common name, DNS names, and IP
  addresses embedded in generated certificates.
- C ABI: `uwz_app_create_tls_ephemeral` and `uwz_app_create_http3_ephemeral`
  mirror the Zig entry points.
- `https_server` example and a `tls_tests.zig` case that completes a full
  TLS 1.3 handshake against a generated certificate over memory BIOs.

### Changed

- The `http3_server` example starts with ephemeral credentials, so it runs
  with no `certs/` directory.
- Generated credentials are created once during context construction and
  released immediately afterwards (the SSL context keeps its own references).
  Connection setup, handshakes, and the I/O loop stay allocation-free.

### Security

- Generated certificates are self-signed and intended for local development
  only; the Zig doc comments and the C header both say so. Production
  deployments keep using `init_https`/`init_http3` with real certificates.
- Ephemeral contexts follow the existing protocol policy: TLS 1.3 only,
  `h2`/`http/1.1` ALPN with the safe-method 0-RTT replay policy on TCP, and
  `h3` ALPN with early data disabled for QUIC.

## [1.4.5] - 2026-09-25

This release completes the capacity redesign: the last fixed per-stream HTTP/2
and HTTP/3 protocol metadata now follows `ServerConfig`, and request-header
overflow is unified across every transport. Public application APIs are
unchanged; the internal storage constructors and the advanced
`configured_app_with_route_params` helper take capacities explicitly.

### Added

- Request header overflow: `Request.add_header` spills beyond the inline 64
  into caller-provided capacity slices (`extra_header_count`), used by the
  HTTP/1.1 parser, the HTTP/2 server session, and HTTP/3 header sets. All
  transports honor `max_header_size` and `max_header_count`.
- HTTP/2 per-stream capacities: `ServerConfig.max_h2_header_block_size`,
  `max_h2_body_size`, `max_h2_response_header_size`, and
  `max_h2_response_header_count` (builder `with_max_h2_*`) size a slab-carved
  session (`Capacities`/`Storage`/`carve_storage`/`Bundle`), so response
  headers, decoded header lists, and request/response bodies are no longer
  fixed at 4 KiB, 32 fields, or 16 KiB.
- HTTP/3 per-stream capacities: `ServerConfig.max_h3_body_size`,
  `max_h3_response_header_size`, and `max_h3_response_header_count` (builder
  `with_max_h3_*`) parameterize `quic_engine`/`stream_with` through
  `stream.Capacities`, and engine-provided header extras spill request headers
  beyond the inline 64.

### Changed

- `http2_server.server_session(max_streams)` replaces the four-argument
  constructor; capacities move to `Capacities`/`Storage` carved from the
  startup slab through `ServerConfig.h2_capacities()`, and per-connection
  session storage lives in a new slab region.
- `quic_engine` takes `stream.Capacities` and `stream_with` takes capacities;
  `QuicStream` and `default_capacities` preserve the previous defaults.
- `configured_app_with_route_params` takes the HTTP/3 capacities as an
  additional compile-time parameter.
- Default capacities match the previous constants, but HTTP/2 session storage
  moved from inline `TcpConnection` arrays into the single startup allocation:
  the default slab grows by the per-connection session region while the pool
  stride shrinks by roughly the same amount per connection.

### Security

- Request-header limits remain enforced at the configured bounds across
  HTTP/1.1, HTTP/2, and HTTP/3. Every new capacity is validated
  (`InvalidHttp2Capacity`/`InvalidHttp3Capacity`) with overflow-checked slab
  and engine math.

## [1.4.0] - 2026-09-25

This release hardens the application helper layer. Every addition is additive,
so 1.3.x applications recompile unchanged apart from the fixes described under
Fixed and Security. The C ABI version moves to 1.4.0 with no structural change.

### Added

- Zero-allocation query parsing: `query.QueryParams` slices `?key=value`
  components out of the request target with SIMD byte scans into a fixed
  struct-of-arrays view (32 pairs) and never copies. `Request.query_params()`
  exposes it directly. `percent_decode` and `form_decode` materialize decoded
  values into caller-owned scratch buffers, so escapes stay borrowed until the
  application asks for them. More than 32 pairs fails closed with
  `error.TooManyQueryParameters`.
- `form` and `Request.form()` validate `application/x-www-form-urlencoded`
  media types and parse the bounded request body with the same slicer.
- `status.StatusCode` and `status.line` provide canonical, typo-proof status
  lines. `errors.send`/`errors.send_buf` render typed JSON error documents
  (`{"error":{"code":...,"message":...}}`) with JSON escaping and no
  allocation, `errors.method_not_allowed` emits a validated `Allow` field, and
  `errors.internal` never echoes internal detail.
- `negotiate` parses `Accept` into a fixed 16-entry table with qvalue scoring
  (`score`, `accepts`, `best`); `Request.accepts(media_type)` is the request
  side entry point.
- `cache` provides deterministic strong ETags (`cache.etag`), If-None-Match
  matching over weak and list validators (`cache.is_not_modified`), and a 304
  sender (`cache.not_modified`).
- JSON schema validation now covers floats (`min_float`/`max_float`), arrays
  and non-u8 slices (`min_items`/`max_items`), whole-string and enum
  membership (`allowed`), and bounded nested validation (`max_nested_depth`).
  `IssueKind` gains typed JSON parse-failure kinds (syntax, unexpected
  end/token, invalid number, overflow, missing/duplicate/unknown field,
  invalid enum tag, length mismatch, item counts) instead of a blanket
  `malformed_json`.
- `cookie` gains a zero-copy `Iterator` over a `Cookie` field, versioned HMAC
  signing (`Key`, `sign_versioned`, `verify_versioned`) for key rotation,
  opt-in `__Host-`/`__Secure-` prefix enforcement through
  `Options.enforce_prefixes`, and pure RFC 9110 date formatting
  (`format_http_date`, `HttpDateBuffer`) with an `Options.expires_unix` field
  that emits `Expires` next to `Max-Age`.
- `Response.json_value` and `json_value_buf` provide named-type alternatives
  to the polymorphic `json`/`json_buf` for dynamic `std.json.Value` payloads.
- The OSS-Fuzz integration adds a fourth target, `query_parse`, with a
  deterministic `query_parse_smoke` executable, seed corpus, and runtime
  options. It fuzzes query slicing, percent/form decoding, and `Accept`
  negotiation, and asserts that every borrowed slice stays inside the parsed
  input. The Smith harness in `zig build test` runs the same code paths.
- `Response.begin_json` returns a `JsonStream` that coalesces JSON into a
  fixed stack buffer and writes chunked response parts, so arbitrarily large
  JSON costs no allocation. Use `stream.stringify()` with `std.json.Stringify`,
  `stream.write`/`write_chunk` for raw bytes with transport errors intact, and
  `stream.end()` to finish. Body size is bounded by the configured
  `with_write_queue_size` ring, not by a rendering buffer.
- Request limits are configurable: `ServerConfig.max_request_line_size`,
  `max_header_size`, and `max_header_count` (with builder `with_*` methods)
  replace the fixed 8 KiB request line, 16 KiB header block, and 64-header
  inline cap. Headers beyond the inline arrays spill into per-connection slab
  storage sized by `max_header_count`, and the 431 rejection document reports
  the configured limit. Defaults keep the previous footprint byte-for-byte.
- `query.QueryParams.get_int` parses the first matching raw value as a
  base-10 integer in one call, and `examples/basic_microservice.zig` shows the
  `GET /search?q=...&page=2` pattern end to end.
- Router capacities are configurable: `ServerConfig.max_route_nodes`,
  `max_pattern_routes`, `max_middleware`, `max_route_path_size`, and
  `max_route_registry_size` (with builder knobs) size a slab-carved router
  whose storage lives in the single startup allocation. Defaults keep the
  previous 256 nodes, 64 patterns, 32 callbacks, 2 KiB paths, and 64 KiB
  registry, and cluster workers now receive the full builder configuration
  instead of the type-level defaults.
- Route captures beyond the inline 16 spill into per-connection capacity
  slices sized by `ServerConfig.max_route_params` / `with_max_route_params` on
  every transport (HTTP/1.1, HTTP/2, and HTTP/3); `UWZ_MAX_ROUTE_PARAMETERS`
  is now a guaranteed minimum rather than a cap, and the C ABI
  `uwz_request_parameter_count` reports the total.
- `Response.begin_stream` pulls a chunked body from a `StreamProducer`
  callback as the transport drains. Producers park with `.pending` on
  `error.WouldBlock` and are re-invoked when output space frees, so a response
  body is not limited by the configured write queue. HTTP/1.1 resumes on write
  completion, HTTP/2 on write completion and WINDOW_UPDATE (window exhaustion
  is normalized to `WouldBlock`), and HTTP/3 on lsquic write drain. Targets
  without a producer callback fail closed with
  `error.ProducerStreamingUnsupported` before writing.
- Query capacity is no longer fixed at 32: `query.QueryParamsOf(capacity)`,
  `Request.query_params_of(capacity)`, and `form.parse_of(capacity, ...)`
  specialize the fixed pair table at compile time; the existing default names
  and overflow behavior are unchanged.

### Changed

- `Response.json_buf` and `Response.json` document their polymorphic contract
  (`std.json.Stringify`-compatible values); their behavior is unchanged.
- HTTP/1.1 response heads (status line, pending fields, explicit fields,
  terminator, body) are written as scatter parts instead of concatenating into
  a fixed buffer. Header size is now bounded by the per-connection write ring
  rather than roughly 4 KiB; HTTP/2 and HTTP/3 keep their own bounded metadata
  storage and limits.

### Fixed

- `errors.render` now writes `code` and `message` with a fixed-buffer JSON
  string encoder. Invalid UTF-8 previously reached `std.json`, which encoded a
  non-UTF-8 slice as a JSON number array, so the document no longer matched the
  documented `"code": "..."` shape. Invalid sequences now become U+FFFD and the
  document is always valid JSON for arbitrary bytes.
- Query components without `=` (`?flag`) now point at the segment end instead
  of a global empty literal, so every borrowed key and value slice lies inside
  the caller's buffer. The fuzz bounds assertions enforce this for empty values
  too.
- The Smith HTTP/query harness no longer reports empty flag values as an
  out-of-bounds failure; the stale `.zig-cache` crash artifact from that false
  positive was removed and the case is covered by
  `src/tests/query_tests.zig`.

### Security

- `Response.append_header` now rejects CR/LF inside a single value. The
  previous validation accepted an embedded `\r\n` as an additional
  well-formed field, so any singular-value helper forwarding untrusted data
  could split the response. Regression coverage lives in
  `src/tests/http_tests.zig`.
- JSON schema parse failures now report a typed `IssueKind` while still
  returning `error.MalformedJson`, so applications can distinguish a syntax
  error from a type mismatch without new allocation.
- Cookie `__Host-`/`__Secure-` prefix enforcement is available but off by
  default, so existing formatters keep their exact bytes until an application
  opts in.

## [1.3.5] - 2026-09-24

This release refreshes every pinned dependency. zslay moves to 0.2.1, lsquic
to 4.10.0, and BoringSSL and ls-hpack advance to their latest upstream
revisions; the lsquic overlay is regenerated against the new source. libxev,
ls-qpack, libdeflate, and zlib were already at their latest upstream refs.
The C ABI is unchanged; the Zig capability constant rename below is the only
source-level break.

### Added

- lsquic 4.10.0 exposes `lsquic_conn_get_full_peer_cert_chain()` and adds the
  `es_max_crypto_stash` engine setting that bounds how many out-of-order
  CRYPTO frames a connection stashes. `lsquic_engine_init_settings` now
  applies the upstream default of 20, so the bound is active without a source
  change.

### Changed

- Dependency: zslay 0.2.0 to 0.2.1 (`farbenbuilds/zslay`). The release changes
  only packaging and Nix metadata, so no call site moved.
- Dependency: BoringSSL `7c1efd8d6ffb36a57feba44e8c73cf674801f3cb` to
  `5fbad2285b096858fc9afa3e4c949fde39452070` (123 upstream commits). The build
  still reads `gen/sources.json`, so upstream added or removed translation
  units compile without a local source-list edit; no public symbol used by
  µWebZockets changed.
- Dependency: lsquic 4.9.3 (`19547405c24f60c4537478d38f4214e990be1f95`) to
  4.10.0 (`d5929af7cec6fd74f1cfea2cb1c07c27ce9102b1`).
  `patches/lsquic_h3_message_error.patch` applies unchanged to the new
  revision, `vendor/lsquic_overlay` was regenerated from the patched sources,
  and `lsquic_versions_to_string.c` names 4.10.0 with an unchanged version
  enum. `scripts/check_vendor_overlay.sh` passes.
- Dependency: ls-hpack `cf0f70dd10b352194c97448eb5d00b4aa484f531` to
  `38ceca78054d4175ba3f6411b1b83ac5c485e542`. Upstream treats over-long EOS
  padding as malformed and fixes a 32-bit fall-through warning; no call site
  moved.
- `http3_extensions.lsquic_4_9_3_capabilities` is renamed to
  `lsquic_4_10_0_capabilities` to track the pinned backend. Migration: replace
  the constant name; the value is unchanged (`.quic_datagrams = true`).
- libxev remains pinned to upstream `main`
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, ls-qpack remains at
  `91567706c41c0d97ab8dc576873ecd472d7869fa`, libdeflate remains at
  `92e6a0db9fa848d742f9eb286c92afc60f2c3dda` (past the v1.26 tag), and zlib
  remains at 1.3.2. Upstream publishes no newer ref for any of them.
- `build.zig.zon.json`, `build.zig.zon.nix`, and `build.zig.zon.txt` were
  regenerated with zon2nix for the zslay 0.2.1 package hash, the BoringSSL and
  lsquic revisions, and the ls-hpack revision.
- Version metadata was bumped to 1.3.5 across `build.zig.zon`,
  `src/version.zig`, `flake.nix`, `include/uWebZockets.h`, the C and C++
  version tests, and the documentation headers.
- Documentation references were refreshed in `README.md`, `SKILL.md`,
  `CODEBASE.md`, `THIRD_PARTY_NOTICES.md`, and the WebSocket and TLS agent
  guides.

### Security

- ls-hpack rejects over-long EOS padding as malformed instead of accepting it
  as valid input.
- lsquic 4.10.0 bounds stashed out-of-order CRYPTO frames at 20 by default,
  limiting the memory a peer can force before the connection aborts.
- BoringSSL advances 123 commits, including the PKI `CertStatus` length check
  and the `X509_verify_cert` issuer-decoding fix.

## [1.3.0] - 2026-09-24

This release adds a terminal development log. It renders connection,
HTTP, and WebSocket events plus the bounded Prometheus counters as colored
lines from fixed stack buffers and writes every record through a thread-local
sink as soon as it is recorded, so the terminal stays real time without
allocating on the event loop. Wire behavior, capacities, and the C ABI are
unchanged.

### Added

- `src/observability/dev_log.zig` implements the allocation-free terminal log.
  `Sink` renders one record into a fixed 4096-byte buffer with comptime format
  strings and ANSI colors, writes it with a single bounded write as soon as it
  is recorded, and counts dropped lines. `thread_sink()` returns the sink owned
  by the calling thread, so recording needs no lock or atomic and the transport
  can reach it without threading a logger pointer through every callback.
- HTTP requests log Vite-style as `HH:MM:SS | [METHOD] /path : STATUS` with a
  dim clock, cyan method, and green, cyan, yellow, or red status by class. The
  exact `µWEBZOCKETS` wordmark from a Zig multiline string is written once at
  startup, followed by a Vite-style ready summary with the version, elapsed
  startup time, and local URL; a terminal
  narrower than the block art gets a one-line `µWebZockets` mark instead, and
  redirected output keeps the full wordmark.
- `src/observability/terminal.zig` probes the output width with a best-effort
  `ioctl(TIOCGWINSZ)` or Windows console query, so the wordmark adapts without
  allocating and without branching on the host OS in portable code.
- `src/observability/file_watch.zig` adds a file watcher:
  `with_watch_paths(&.{"src"})` streams `watch` lines for created, modified,
  and deleted files, so saves appear in the terminal as they happen. Linux
  reads inotify through the event loop for real-time changes; every other
  target scans the roots on a 500 ms loop timer. The watch set is bounded,
  skips build and VCS directories, requires `enable_dev_log`, and never
  allocates per event.
- `dev_log.Record` carries the wall clock, severity, and an explicit
  `Direction` (`data_in` or `data_out`) beside a named event payload
  (`connection_opened`, `connection_closed`, `http_request`, `ws_message`,
  `metric`), so no ambient logger state exists.
- `ServerConfig.enable_dev_log` defaults on, so every example shows the log
  when run in a terminal. The default stderr sink stays quiet when stderr is
  not a terminal, which keeps redirected runs and the throughput benchmark
  free of per-record writes; `App.set_dev_log_file` binds an output that always
  records. `App.flush_dev_log` and `App.log_metrics` expose any pending bytes
  and the counter snapshot, and setting the toggle false silences every
  development-log write.
- Every `zig build <example>` run in a terminal shows the wordmark, ready
  summary, request lines, and (with `with_watch_paths`) file changes.
- Unit coverage in `src/tests/dev_log_tests.zig` pins the rendered byte
  sequences, immediate write behavior, oversize drops, comptime metric names,
  and the thread-local sink identity.

### Changed

- `TcpConnection` now carries the thread-local dev-log sink and the optional
  counter registry, so the HTTP/1.1 and WebSocket paths emit records and
  advance counters without allocating. HTTP/2 dispatch and QUIC callbacks
  remain silent in this release.
- The `uwz_connections_accepted`, `uwz_connections_closed`,
  `uwz_http_requests`, and `uwz_ws_messages` counters now advance at their
  accept, close, dispatch, and complete-message sites when observability is
  enabled; they were previously defined but never incremented.
- `src/root.zig` exports `dev_log` for downstream consumers.

### Security

- No security-relevant behavior changed. The development log is opt-in,
  silent by default, writes only to the caller-bound file, and performs no
  dynamic allocation; parsing, validation, and wire behavior are unchanged.

## [1.2.0] - 2026-09-24

This release makes the repository a self-contained Zig package. Every C and
C++ dependency is compiled by Zig's own toolchain from pinned sources; the
public API, wire behavior, capacities, ownership semantics, C ABI, and
application logic are unchanged.

### Added

- Native dependency builders in `builds/vendor/`: `boringssl.zig`,
  `lsquic.zig`, `libdeflate.zig`, and `zlib.zig` compile the static vendor
  libraries with
  `zig cc` and `zig c++` instead of CMake, Ninja, Go, Perl, `patch`, or a
  system zlib. `builds/vendor/root.zig` links the resulting artifacts
  transitively.
- `vendor/lsquic_overlay/` holds the pre-generated
  `lsquic_versions_to_string.c` and the pre-patched `lsquic_qdec_hdl.{c,h}`
  and `lsquic_stream.c`, so the build no longer runs `gen-verstrs.pl` or
  applies `patches/lsquic_h3_message_error.patch` at build time. The patch
  remains the auditable source of the overlay.
- Bundled zlib 1.3.2 as a pinned package dependency for the RFC 7692 small
  windows and gQUIC certificate compression that libdeflate cannot express.
- `scripts/check_vendor_overlay.sh` verifies the overlay against the audit
  patch and the pinned lsquic version enum; the lint workflow runs it.
- `zig build clangd` writes a gitignored `compile_flags.txt` at the repository
  root with the fetched dependency include roots, so editors can analyze
  `src/c.h`, the lsquic shim, and the C ABI tests.

### Changed

- BoringSSL is compiled from the pinned package's `gen/sources.json` source
  lists, with the committed `gen/crypto/err_data.cc` and perlasm sources used
  as shipped upstream. Windows and MemorySanitizer builds disable assembly
  exactly as upstream does.
- ls-qpack and ls-hpack remain pinned package dependencies compiled as one
  translation unit each; neither has a generation step, architecture-specific
  source, or system tool requirement.
- libdeflate keeps its runtime dispatch: the AVX-512 and VPCLMULQDQ paths are
  disabled because the bundled Clang requires the explicit `evex512` target
  feature, and dispatch falls back to AVX2 and SSSE3.
- Vendor C and C++ is compiled with explicit upstream-compatible flags.
  Zig's release modes are stopped from injecting undefined-behavior traps,
  `_FORTIFY_SOURCE`, and stack protectors into third-party code: lsquic's
  packet-header path tripped an injected `ud1` trap in the HTTP/3 server, and
  the fortified wrappers also hide zeroed buffers from MemorySanitizer. The
  sanitizer modes still enable their own reporting checks afterwards.
- `build.zig.zon` adds the zlib dependency; `build.zig.zon.json`,
  `build.zig.zon.nix`, and `build.zig.zon.txt` were regenerated.
- The `vendor/boringssl`, `vendor/lsquic`, and `vendor/libdeflate` audit
  submodules were removed. Only the `vendor/h1spec` compliance submodule and
  the `vendor/lsquic_overlay` build input remain; vendor license texts live in
  `licenses/vendor/`, and `scripts/check_vendor_overlay.sh` fetches the pinned
  lsquic package instead of reading a local checkout.
- `flake.nix` provides Zig plus development tooling only. CI caches Zig's
  content-addressed package and local caches instead of the CMake/Ninja
  vendor trees, and the timestamp-refresh workaround is gone.
- Removed the `-Dzlib-prefix` option, the `UWEBZOCKETS_ZLIB_PREFIX`
  environment variable, the Windows vcpkg zlib bootstrap under
  `scripts/windows`, `scripts/prepare_lsquic_source.sh`, and the `zig-cc` and
  `zig-c++` compiler wrappers.
- Release archives include the bundled zlib license next to the other
  third-party notices.

### Security

- No security-relevant behavior changed. Dependency revisions, compiler
  flags, sanitizer instrumentation, and validation bounds are unchanged; the
  packaged libraries are built from the same pinned sources as before.

## [1.1.9] - 2026-09-23

This release is a type-readability pass. Wire behavior, capacities, ownership
semantics, exported names, and field layouts are unchanged.

### Added

- Named callback aliases on the public surface: `Http3EndFn`, `Http3BeginFn`,
  `Http3WriteFn`, `Http3FinishFn`, `Http2EndFn`, `Http2BeginFn`,
  `Http2WriteFn`, `Http2FinishFn`, `AsyncCompleteFn`, and `AsyncWakeFn` in
  `Response`; `WsUpgradeCallback`, `WsOpenCallback`, `WsMessageCallback`,
  `WsDrainCallback`, and `WsCloseCallback` in `WsBehavior`; `CloseCallback`
  and `TickCallback` in the transport; `ReadableReadFn`, `ReadableCloseFn`,
  `WritableWriteFn`, `WritableCloseFn`, and `WritableBackpressureFn` in
  `streams`; `WriteFn`, `RequestFn`, `WsDataFn`, and `StreamClosedFn` in the
  HTTP/2 server session.
- Named HTTP/2 event payloads extracted from the `Event` union:
  `DiscardedDataEvent`, `StreamResetEvent`, `GoAwayEvent`, and
  `WindowUpdateEvent`.
- Explicit `ServerConfig.Overrides` record for `ServerConfig.with`, replacing
  the reflection-driven `anytype` parameter with 13 documented optional
  fields.
- Named route payloads (`ContextualRoute`, `ContextualAsyncRoute`), a named
  `SocketFd` for the transport descriptor helpers, named C ABI trampoline
  tables, and protocol-bound aliases such as `ControlFrameBuffer` and
  `AcceptTokenBuffer`.

### Changed

- `ServerConfig.with` now accepts `ServerConfig.Overrides`. Anonymous struct
  literals (`.with(.{ .max_body_size = 256 * 1024 })`) coerce unchanged;
  passing a full `ServerConfig` value as the override argument is no longer
  accepted.
- `close_socket`, `request_quickack`, and `apply_listener_tuning` take the
  named `SocketFd` instead of `anytype`, and the now-redundant runtime type
  probe in `close_socket` is gone.
- `register_typed_context` validates its context pointer through the named
  `mutable_context_pointer` comptime helper.
- Documentation records the mandatory type-readability contract in
  `CODING_CONVENTION.md` section 8 and mirrors it in `README.md`, `AGENTS.md`,
  `SKILL.md`, `CODEBASE.md`, and `CONTRIBUTE.md`; `docs/callback_lifecycle.md`
  source references were re-synchronized with the tree.

### Security

- No security-relevant behavior changed. Recovery paths, validation bounds,
  and C ABI layouts are identical to 1.1.7.

## [1.1.7] - 2026-09-23

This release tracks the zslay 0.2.0 frame-parser surface. Wire behavior,
capacities, and ownership semantics are unchanged.

### Added

- Adopted the zslay 0.2.0 pure close-payload validator
  (`zslay.validate_close_payload`) in `src/ws/socket.zig`, so close codes and
  UTF-8 reasons share one validation source with the frame parser instead of a
  local duplicate scanner.

### Changed

- Dependency: zslay 0.1.9 to 0.2.0 (`farbenbuilds/zslay`). The release adds the
  pure `validate_close_payload` helper and the `1012`, `1013`, and `1014` close
  status codes, fixes `Conn.get_tx_header_buffer` to return a slice into the
  queued node instead of a local copy (removing a use-after-return) with an
  empty TX queue now yielding an empty slice, and adds the additive
  `zslay_conn_reset` C export. No existing zslay call site changes shape.
- `build.zig.zon.json`, `build.zig.zon.nix`, and `build.zig.zon.txt` were
  updated for the v0.2.0 package hash and URL.
- Version metadata was bumped to 1.1.7 across `build.zig.zon`,
  `src/version.zig`, `flake.nix`, `include/uWebZockets.h`, the C and C++
  version tests, and the documentation headers.
- Documentation references to zslay were refreshed in `README.md`, `SKILL.md`,
  `CODEBASE.md`, `THIRD_PARTY_NOTICES.md`, and the WebSocket agent guide.

### Security

- Close-frame validation delegates to zslay 0.2.0: one-byte payloads and
  reserved close codes return `error.ProtocolError`, invalid UTF-8 reasons
  return `error.InvalidUtf8`, and µWebZockets keeps its 125-byte control-frame
  bound on top of the pure validator.

## [1.1.5] - 2026-09-22

This release tracks the zslay 0.1.9 frame-parser surface and confirms libxev is
already at the latest upstream revision. Wire behavior, capacities, and
ownership semantics are unchanged.

### Added

- Adopted the zslay 0.1.9 named wire constants `zslay.MaxFrameHeaderLen` and
  `zslay.FrameHeaderBuffer` in the WebSocket tests, replacing the local 14-byte
  header literals.
- `zslay.ConnConfig` is now named explicitly where the server WebSocket
  context is constructed in `src/ws/socket.zig`.

### Changed

- Dependency: zslay 0.1.5 to 0.1.9 (`farbenbuilds/zslay`). The release renames
  `DecodedHeader.extended_len` and `DecodedHeader.header_size` to `payload_len`
  and `header_len`, moves `FrameNode` to the module root with `header_len`,
  `header_sent`, and `payload_sent` fields, and replaces the loose
  fragmentation fields with `rx_fragment` and `tx_fragment`. `src/ws/socket.zig`,
  `src/tests/ws_tests.zig`, and `src/tests/fuzz_main.zig` follow the new names.
- `build.zig.zon.json`, `build.zig.zon.nix`, and `build.zig.zon.txt` were
  regenerated with zon2nix for the new package hash.
- libxev remains pinned to upstream `main`
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`. Upstream publishes no newer tag,
  release, or commit, so no pin change was required.
- Documentation references zslay 0.1.9 in `README.md`, `SKILL.md`,
  `CODEBASE.md`, and `THIRD_PARTY_NOTICES.md`. `SECURITY.md` tracks the `1.1.x`
  line as the supported release, and the WebSocket, transport, router, and TLS
  agent guidance was corrected to match the current code (zslay pin, 0-RTT
  policy, lock-free cluster ring, and current `file:line` references).

### Security

- No security-relevant behavior changed. Frame validation, masking, and message
  limits stay enforced by µWebZockets; zslay 0.1.9 adds no new live protocol
  path to the server.

## [1.1.1] - 2026-09-22

This release tightens the functional-purity contract across the library and
makes it machine-checked. No wire behavior, capacity, or ownership semantics
change.

### Added

- Named HTTP/2 frame event payload types (`HeadersEvent`,
  `HeadersContinuationEvent`, `DiscardedHeadersEvent`, `DataEvent`) in
  `src/http2/connection.zig`.
- `CODING_CONVENTION.md` section 7, the mandatory functional-purity and
  anti-slop contract: no OOP or hidden state, pure transformations, explicit
  types over `anytype` at module boundaries, scoped logging instead of console
  output, no dead code or TODO markers, three-level control-flow limit, no
  forwarding wrappers, and error-discipline rules.
- `AGENTS.md` Code Hygiene section so agents apply the same contract and run
  the format, convention, release, and test gates.
- `scripts/check_conventions.sh` now rejects `std.debug.print` and direct
  stdout/stderr writes in `src/`, plus `TODO`, `FIXME`, `XXX`, and `HACK`
  markers in the Zig sources.

### Changed

- `src/http2/server.zig` frame handlers take the named event payload types
  instead of `anytype`, so every payload shape is checked at compile time.
- Transport and TLS diagnostics in `src/core/tcp.zig`, `src/core/udp.zig`,
  `src/core/timer.zig`, `src/router/app.zig`, and `src/crypto/handshake.zig`
  use `std.log.scoped` at the matching severity; the listening messages are
  `info`, recoverable I/O failures are `warn`, and cancellation noise is
  `debug`.
- Removed unused imports in `src/router/app.zig`, `src/http/streams.zig`,
  `src/ws/stream.zig`, and `fuzz/http_framing.zig`.
- `CONTRIBUTE.md` and `SKILL.md` point contributors and agents at the section 7
  contract.

### Security

- No security-relevant behavior changed; diagnostics no longer write directly
  to stderr, so host logging policy applies to every transport error.

## [1.1.0] - 2026-09-19

This release adds the unreliable low-latency datagram surface, an opportunistic
AF_XDP transport, and continuous kernel-level observability. Every new hot path
draws from the one startup slab and performs no heap allocation.

### Added

- WebTransport datagram routing in the server builder.
  `Server.builder(...).with_webtransport_datagrams(max_size, slots)` reserves
  the capacity and applications register session paths with `App.datagram` or
  `App.datagram_context`, mirroring the HTTP route surface. One `DatagramRing`
  per connection is carved from the startup slab as parallel metadata arrays
  plus a fixed-stride payload region, so enqueue and drain never allocate; a
  full ring drops without blocking the transport and increments
  `datagrams_dropped`. `App.dispatch_datagram` is the HTTP/3 DATAGRAM boundary
  and `App.next_datagram` drains a connection's queued copies.
- `src/quic/datagram_ring.zig`, a bounded SoA FIFO over caller storage with
  wrapping u32 cursors, drop-oldest support, and a lifetime drop counter.
- `Preset.webtransport_realtime` reserves 1200-byte datagrams at depth 64 for
  512 connections and enables the metrics endpoint.
- Opt-in AF_XDP kernel bypass. `Preset.kernel_bypass` and
  `with_kernel_bypass(true)` request the zero-copy path. `resolve_mode` removes
  the request at compile time on non-Linux targets, and the runtime probe falls
  back to the standard stack when the kernel or process privileges refuse
  AF_XDP while recording the reason in `transport_availability`. The UMEM
  region is page aligned inside the same startup slab as the connection pools,
  and `src/xdp/transport.zig` owns the rings with a fixed free-frame stack so
  frame recycling never allocates.
- `src/xdp/socket.zig` now maps the TX ring, validates descriptor bounds, and
  exposes `receive_frame`, `release_frame`, `transmit_frame`, and `reclaim_tx`.
- Continuous eBPF observability. `src/observability/metrics.zig` renders a
  fixed-capacity counter registry and an optional kernel latency histogram into
  Prometheus text through one `std.Io.Writer.fixed` cursor, so formatting never
  allocates. The hidden `/metrics` route (configurable with `with_metrics_path`)
  serves it from a fixed stack buffer and folds in the pinned `uwz_latency`
  per-CPU histogram through `src/observability/ebpf.zig`.
- `src/observability/uwz_latency_bpf.c` and the extended `zig build ebpf` step
  build the XDP redirect and latency histogram objects from one pipeline.
- `with_observability(true)` carves a cache-line-aligned registry in the
  startup slab; `observability`, `ebpf`, `xdp_transport`, `datagram`, and
  `datagram_ring` are exported from the package root.

### Changed

- `ServerConfig` gains `transport`, `max_datagram_size`, `datagram_slots`,
  `xdp_frame_size`, `xdp_frame_count`, `observability`, and `metrics_path`.
  `required_alignment` reports the page alignment the bypass layout needs;
  `init_configured` allocates with it and `init_from_slab` rejects misaligned
  storage with `error.MisalignedSlab`.
- The centralized test module re-exports the new modules through
  `test_support`, so the suite runs without relative imports outside the module
  root.
- `src/version.zig` is now the single Zig source of truth for the release
  version; `build.zig` derives its `std.SemanticVersion` from it, and the C ABI
  and OpenAPI defaults read the same module. `scripts/bump_version.sh` rewrites
  the manifest, C ABI macros, C/C++ version assertions, documentation headers,
  and the changelog skeleton in one command, and
  `scripts/check_release_version.sh` fails lint CI when any copy drifts.

### Security

- AF_XDP remains a request, never an assumption: probe and ring failures cannot
  fail startup and always leave the standard transport serving traffic.

## [1.0.9] - 2026-09-18

This release supersedes the unreleased 1.0.7 and 1.0.8 lines: their planned
transport and protocol work ships here together with the zero-copy, 0-RTT, and
BBR boundaries.

### Added

- Zero-copy static file streaming. `Response.send_file` and
  `TcpConnection.begin_file_response` hand an open regular file to the kernel
  with `sendfile` on Linux and macOS, so body bytes never cross a user-space
  buffer and large assets are no longer capped by the per-route file buffer.
  The connection takes ownership of the descriptor on success, serves RFC 9110
  byte ranges with an exact `Content-Length`, answers HEAD without streaming,
  and closes the descriptor when the body drains or the peer disappears.
- `src/core/zero_copy.zig` with the per-platform kernel transfer boundary.
  libxev sockets are blocking (io_uring creates them without `O_NONBLOCK` and
  Linux does not inherit the flag through `accept`), and a blocking `sendfile`
  sleeps until its full count is transferred, so the transport opens a
  temporary nonblocking window for the transfer and closes it before queueing
  any completion. Bytes that `EAGAIN` fall back to a bounded dribble that
  reuses the idle TLS staging buffer, and one tick transfers at most four
  kernel chunks. Windows keeps the bounded buffered path because libxev owns
  the IOCP completion port, so an overlapped `TransmitFile` cannot be observed
  by the event loop without stalling a worker.
- HTTP/1 dispatch now suspends pipelined request processing while a kernel file
  body is in flight, so a later response can never interleave with it.
- TLS 1.3 0-RTT (early data) on the HTTPS context via BoringSSL
  `SSL_CTX_set_early_data_enabled`. Early data is replayable, so only safe
  methods (`GET`, `HEAD`, `OPTIONS`) are dispatched before the handshake is
  confirmed; anything else receives `425 Too Early`. The HTTP/1.1 rejection
  also closes the connection, while HTTP/2 rejects the individual stream.
  Rejected early data is never dispatched: BoringSSL drops it and completes the
  full handshake in place, so no reset path is needed on the server.
- QUIC BBR congestion control. The lsquic engine now pins `es_cc_algo` to BBRv1
  and enables per-connection pacing explicitly, replacing lsquic's adaptive
  default that falls back to CUBIC at low RTT.
- Regression coverage for the kernel sendfile path and the BBR engine policy.

### Changed

- `static_files` parses the request range before touching the file body, then
  attempts the kernel path and only falls back to the bounded buffer for TLS,
  HTTP/2, HTTP/3, and oversized assets.
- `TlsContext.init_with_alpn` takes an explicit early-data policy; the HTTP/3
  context keeps 0-RTT disabled until lsquic replay protection is defined end to
  end.

### Security

- 0-RTT admits safe, idempotent methods only on both HTTP/1.1 and HTTP/2. The
  HTTP/1.1 rejection closes the connection so a replayed request cannot be
  retried as-is on the same connection.

## [1.0.6] - 2026-09-17

### Added

- Added `ServerConfig`, named `Presets` (`microservice`, `websocket_chat`,
  `file_server`), and the fluent `Server.builder` API with compile-time
  `with_*` overrides that translate named limits into one contiguous startup
  slab.
- Added `Server.builder(...).build(allocator)`, `App.init_configured`, and
  `App.init_from_slab`, which carve the connection pool, HTTP/1.1 request
  buffers, WebSocket message regions, response write queues, and optional
  RFC 7692 scratch from a single block.
- Added structured JSON transport rejections: oversized bodies return `413`
  and oversized headers return `431` with a document naming the configured
  limit and the `ServerConfig` field to raise.
- Added `examples/basic_microservice.zig` and `examples/custom_builder.zig`
  with matching `zig build` steps.
- Added physical-core affinity and shared-nothing startup options:
  `App.cluster(...).init_with_options`, `Server.builder(...).build_cluster`, and
  `ClusterOptions` pin worker `i` to the `i`-th allowed physical core on Linux
  and Windows while keeping restricted cpusets and affinity-less platforms
  running unpinned.
- Added listener and connection tuning: `SO_REUSEPORT` on POSIX,
  `TCP_DEFER_ACCEPT` on listeners, and a one-shot `TCP_QUICKACK` request at
  accept so the hot read path stays syscall-free.
- Added a lock-free Vyukov sequence ring for cluster inboxes, removing the
  spinlock from the cross-worker wakeup path and cache-line separating the
  producer and consumer positions.
- Added `examples/shared_nothing_cluster.zig` plus the restructured
  `docs/architecture.md`, `docs/memory_model.md`, `docs/protocols.md`, and
  `docs/operations.md`.

### Changed

- Moved per-connection HTTP/1.1 request buffers out of `TcpConnection` into
  the application slab; the parser now enforces a per-connection
  `max_body_size` policy instead of the fixed module default.
- `freelist_pool` can adopt caller-owned storage through `from_slices` and
  leaves that storage intact in `deinit`.
- `App.init` keeps its existing signature and now builds the same single slab
  through `init_configured`.
- Windows cluster listeners fall back to `SO_REUSEADDR` and thread affinity to
  `SetThreadAffinityMask` instead of failing when `SO_REUSEPORT` is missing.
- Rewrote `README.md` as a short onboarding document and moved deep runtime,
  memory, protocol, and operations material into `docs/`.
- Normalized naming to the coding convention: the JSON-RPC standard-error
  namespace is now `StandardError` and the internal builder type generator is
  `configured_builder`. The convention checker now also rejects PascalCase
  function names, snake_case type names, and camelCase fields or parameters.

### Fixed

- Fixed an HTTP/2 stream-lifecycle race: an `END_STREAM` HEADERS frame no
  longer releases its slab slot before the server finishes processing the
  event, the server refuses to emit `RST_STREAM` on stream 0, and a second
  HEADERS section on a stream without a completed request is rejected as an
  unexpected trailer.
- Enforced `ServerConfig.max_body_size` for HTTP/2 request bodies, both
  declared and streamed, within the compiled session slab capacity.
- Fixed macOS/kqueue connection-slot and QUIC-drain leaks: canceled read and
  write callbacks that the backend can drop no longer gate slab release, and
  the close completion clears the outstanding flags.
- Fixed a shutdown hang where stopping a timer or the idle sweeper from inside
  its own tick callback re-armed it forever.
- Fixed QUIC shutdown re-entrancy: `shutdown()` from an HTTP/3 handler now
  defers `lsquic_engine_cooldown` until the active engine callback unwinds.
- Fixed WebSocket fatal-error handling: a failed parser is terminal, a close
  frame completes the frame parser instead of being re-emitted, HTTP/2 tunnels
  are reset on failure or close, and large sends split across DATA frames
  instead of committing a frame header before a rejected payload.
- Fixed an absolute-path escape in static file index appending and made static
  file traversal open every directory component without following symlinks.
- Fixed JSON-RPC perfect-hash dispatch to confirm stored method bytes after a
  fingerprint match, and widened the router's copied-path registry offset so
  filling the 64 KiB limit cannot overflow.
- Fixed slab-plan alignment so near-maximum layouts return
  `error.SlabSizeOverflow` instead of panicking, and rejected `ServerConfig`
  capacities that do not match the generated `App` type at compile time.
- Fixed `If-None-Match` precedence over `If-Modified-Since`, OpenAPI literal
  `:`/`*` path segments, `Cluster.deinit` double-call safety, the TLS plaintext
  drain continuing after close was scheduled, and the native stream adapter's
  zslay opcode names.

## [1.0.5] - 2026-09-14

### Added

- Added native, `wasm32-freestanding`, `wasm32-wasi`, and Linux eBPF build
  targets behind a thin root orchestrator and decomposed the CMake/Ninja,
  sanitizer, test, fuzz, example, and target logic under `builds/`.
- Added a transport-independent protocol core, a pull-based `WebSocketStream`,
  WHATWG-style BYOB reads, and an immutable backpressure transition function.
- Added bounded libdeflate compression streams, BoringSSL SHA-256, HMAC-SHA256,
  and AES-GCM primitives, plus generation-safe cooperative cancellation for
  streams, RPC dispatch, timers, and pooled TCP connection lifecycles.
- Added generation-checked shared memory with a bounded Cap'n Proto envelope
  for zero-copy WASM host views.
- Added a Linux AF_XDP socket with UMEM ownership rings and an XDP redirect
  program, plus kTLS configuration and zero-copy `sendfile`/`splice` helpers.
- Added SIMD HTTP delimiter and field-value scanning and compile-time JSON-RPC
  perfect-hash services with constant-time table lookup.

### Security

- Reject stale shared-memory and cancellation handles across owner reuse, clear
  released FFI blocks, authenticate AES-GCM before exposing plaintext, and use
  constant-time HMAC verification.
- Retained strict bounded HTTP framing, conflicting transfer-length rejection,
  header control-character rejection, idle connection expiry, and allocator
  lifecycle leak checks.

## [1.0.4] - 2026-09-13

### Added

- Added fixed-capacity JSON-RPC 2.0 services with bounded method ownership,
  open-addressed dispatch, typed procedure adapters and results, context
  handlers, notifications, batches, standard protocol errors, application
  faults, and `App.rpc` HTTP mounting.

### Fixed

- Validate complete JSON-RPC batches before invoking procedures so malformed
  tails cannot commit prefix side effects behind a parse-error response.
- Retry transient connection resets in Autobahn readiness probes between
  isolated compliance batches.

## [1.0.3] - 2026-09-12

### Added

- Added bounded static asset serving with MIME detection, ETags,
  Last-Modified validation, cache control, single byte ranges, and
  traversal-safe directory-relative file access.
- Added zero-allocation multipart form parsing with borrowed chunk iteration,
  signed cookie/session helpers, CORS and security-header middleware,
  reflected JSON constraints, Server-Sent Events, and OpenAPI 3.1 route output.
- Added a native thread-per-core cluster manager with fixed cross-thread
  message queues, event-loop wakeups, shared pub/sub fan-out, and reusable
  listener ports.
- Added configurable WebSocket ping intervals and pong timeouts using the
  existing data-oriented connection sweep.
- Added portable SIMD delimiter search with scalar tail handling for multipart
  parsing.

### Fixed

- Kept Git tags in v<version> form while publishing GitHub release titles as
  uWebZockets v<version> on both release creation and later edits.
- Assigned Windows build deployments to the separate Windows Publishing
  environment.
- Rejected multipart boundary-prefix sequences that are not complete delimiter
  lines.

## [1.0.2] - 2026-09-12

### Added

- Added Windows target support (`x86_64-windows-gnu` / MinGW ABI) using Windows
  IOCP non-blocking I/O through `libxev`.
- Added Windows socket abstraction (`core_tcp.close_socket`, `c.closesocket`
  vs `close`, `lsquic_api` `WSASendTo` scatter-gather batch packet sending, and
  `mswsock` extension).
- Added Windows ABI compatibility for `uz_lsxpack_header` in C shims, accounting
  for 4-byte enum bitfield alignment.
- Added native Windows CI that compiles the `x86_64-windows-gnu` test graph and
  static libraries, plus a Windows archive in tagged GitHub releases.
- Added Fetch-inspired ergonomics to `Request` (`headers` view,
  `text()`, `bytes()`, `json()`, `url()`) and `Response` (`text()`, `html()`,
  `bytes()`, `json()`, `json_buf()`, `redirect()`, `writable_stream()`).
- Added Streams-inspired adapters (`ReadableByteStream` with BYOB and chunk
  readers, `WritableByteStream`, and `pipe_to`).
- Added optional borrowed fallback parameter and header slices for external
  request adapters while retaining fixed-capacity built-in parsers.
- Added RFC 8441 extended CONNECT support for WebSocket upgrade over HTTP/2
  streams (`SETTINGS_ENABLE_CONNECT_PROTOCOL`), mapping frames across stream DATA
  payloads.

### Fixed

- Isolated Autobahn compression datasets in fresh containers, merged their full
  results before gating, and retried a killed batch once with a fresh server.
- Grouped Windows compiler wrappers under `scripts/windows`.
- Made `tests/c_api/smoke.c` cross-platform for Windows and POSIX with
  `WSAStartup`/`WSACleanup`, `SOCKET` abstraction, `close_socket()`, and `send()`.
- Centralized release metadata validation so the package, Nix, C ABI, tests,
  changelog, and documentation cannot silently disagree about the version.
- Guarded host `zlib_prefix` in `build.zig` to only apply to native targets,
  preventing host ELF static archives from interfering with Windows cross-compilation.
- Rejected CR/LF in redirect destinations before formatting the `Location`
  field.
- Bound header-view iteration and byte-stream callback counts to their borrowed
  slices, and close both stream adapters after transfer failures.
- Bound HTTP/2 WebSocket state to one active tunnel per connection, removed
  stale pub/sub state on every teardown path, and rejected DATA for unaccepted
  extended CONNECT streams.
- Deferred terminal HTTP/2 DATA stream release until event processing finishes,
  preventing one stream from closing its multiplexed connection.
- Mapped Winsock send errors to the C errno values expected by lsquic and used
  `closesocket` for Windows transport sockets.
- Kept HTTP/3 extended CONNECT and WebTransport helpers detached from the live
  listener until backend negotiation and application policy can be enforced.

## [1.0.1] - 2026-09-01

### Fixed

- Fixed macOS release builds by routing TCP, UDP, and listener cancellation
  through a kqueue-compatible libxev adapter.
- Fixed Nix dev-shell evaluation by using the package set supplied by
  `flake-parts` instead of recursively replacing its compiler stdenv.
- Fixed macOS release metadata validation by replacing the Bash 4-only
  `mapfile` builtin with Bash 3.2-compatible version parsing.
- Removed Deno from the Nix dev shell and made `zon2nix` conditional on
  platform support, preventing unnecessary `rusty-v8`/glibc builds and
  unsupported Darwin shell evaluation.
- Kept host utilities native in the musl dev shell so `direnv` does not
  rebuild target-libc copies of unrelated development tools.

## [1.0.0] - 2026-09-01

### Added

- Added bounded `ConfiguredApp` storage for per-connection WebSocket messages
  and output queues.
- Added method-aware HTTP routes for GET, HEAD, POST, PUT, DELETE, PATCH,
  OPTIONS, and fallback handlers.
- Added query/path separation, duplicate-header inspection, HEAD fallback,
  automatic OPTIONS and `Allow`, `100 Continue`, and chunked responses.
- Added WebSocket upgrade authorization, frame/message limits, close handling,
  drain notification, buffered-byte reporting, streaming UTF-8 validation, and
  SIMD masking.
- Added RFC 7692 per-message deflate with strict offer parsing, mandatory
  client/server no-context-takeover, 9-15 bit server and 8-15 bit client window
  negotiation, bounded decompression, and startup-allocated per-connection
  scratch storage.
- Added HTTPS with BoringSSL TLS 1.3 and `h2`/`http/1.1` ALPN.
- Added a bounded HTTP/2 connection state machine with a fixed-capacity
  structure-of-arrays stream slab, strict frame sequencing, settings and
  flow-control validation, and caller-owned HPACK dynamic-table, Huffman,
  request-decoding, and response-encoding storage. Integrated eight-stream
  routing into plaintext prior-knowledge and TLS ALPN listeners.
- Added a bounded HTTP/3 server adapter over lsquic with direct QPACK-to-Request
  decoding, structured response headers, fixed stream/header/packet pools,
  partial-write handling, and shared HTTP route dispatch.
- Added `ConfiguredAppWithTimeout`, a 120-second default idle policy, and the
  option to disable idle sweeping with a zero timeout.
- Added exact and parameterized routing. `:name` captures one nonempty segment,
  terminal `*name` captures the remaining path including an empty remainder,
  and every request stores at most 16 borrowed captures without allocation.
- Added 32-entry ordered middleware, context-aware handlers, and generation-
  checked one-shot asynchronous response tokens for Zig applications.
- Added a versioned C ABI with opaque application, request, response, and
  WebSocket handles, predictable integer errors, explicit shutdown/destroy,
  synchronous and one-shot asynchronous routes, ordered middleware, borrowed
  route parameters, and the installed `include/uWebZockets.h` header.
- Added RFC 10008 `QUERY` routing and mandatory media-type validation to the
  Zig and C APIs while preserving the stable numeric value of `ANY`.
- Added HTTP/3 helpers for RFC 9220 extended CONNECT validation, bounded server
  push bookkeeping, and explicit early-data policy. Added bounded
  WebTransport-over-HTTP/3 draft-16 settings, CONNECT, session, stream,
  datagram, capsule, flow-control, and error-mapping primitives.
- Added Autobahn and h1spec compliance servers and GitHub Actions workflows,
  including a Deno-orchestrated Autobahn runner with deterministic cleanup and
  report gating.
- Added bounded HTTP, HTTP/3 metadata, zslay, and WebSocket extension fuzz
  coverage. Added Google OSS-Fuzz/libFuzzer entrypoints for HTTP framing,
  WebSocket masking, and QUIC/WebTransport packet boundaries, with seed
  corpora, dictionaries, and deterministic local smoke targets.
- Added a pinned curl/ngtcp2 and aioquic HTTP/3 interoperability gate, including
  a valid trailing field section plus duplicate pseudo-header, pseudo-header
  ordering, and connection-specific header rejection probes. Malformed and
  healthy sibling streams share one connection, require `H3_MESSAGE_ERROR`,
  and retain qlog evidence.
- Added the versioned `http-throughput-v1` regression contract, pull-request
  comparison gate, and append-only benchmark history publication.
- Added Nix native/musl packages, six-target publishing, checksums, deployment
  environments, and third-party license packaging.
- Added native-Linux ASan, UBSan, LeakSanitizer, and Zig C-UB test mode for the
  Zig/C/C++ graph, with an isolated sanitizer vendor cache.
- Added a mutually exclusive native x86_64 Linux MemorySanitizer mode with
  origin tracking, full pinned C/C++ instrumentation, an isolated cache, and
  a dedicated CI run.

### Changed

- Updated zslay from 0.1.1 to 0.1.5 using the immutable v0.1.5 source archive.
- Migrated WebSocket parsing to zslay 0.1.5's role, frame-node, length-limit,
  and error APIs.
- Reworked connection ownership into a contiguous slab with an activity bitmap
  and deterministic release.
- Reworked application shutdown into an idempotent completion-driven drain;
  new work is rejected before accept, TCP, timer, UDP, and QUIC resources are
  stopped and released in ownership order.
- Extracted the UDP/QUIC socket lifecycle into `src/core/udp.zig`; its fixed receive
  buffer, read, timer, cancellation, close, and drain completions are owned by
  one transport and used by `App.listen_udp`.
- Reworked routing as fixed-capacity parallel arrays and made duplicate,
  invalid, or excessive routes return errors. Route mutation is locked after
  either listener starts.
- Centralized ordinary Zig unit tests under `src/tests/`, with
  `src/tests/main.zig` as the `zig build test` root. Its
  `src/tests/fuzz_main.zig` Smith harness also serves as the dedicated
  `zig build fuzz` root.
- Reworked TCP and TLS writes to preserve partial writes in bounded queues and
  signal backpressure.
- Reworked pub/sub to own bounded topic names and remove stale subscribers.
- Mapped Zig optimization modes and target triples into isolated CMake/Ninja
  builds for BoringSSL, lsquic, and libdeflate.
- Moved BoringSSL, lsquic, ls-qpack, ls-hpack, and libdeflate source selection
  to immutable Zig package URLs and hashes so downstream path dependencies do
  not depend on the repository's vendor submodules.
- Added a downstream path-dependency compile fixture and installed
  `uWebZockets.h` through both the normal install and library-only steps.
- Pinned Nixpkgs 26.05 so GNU/Linux, musl/Linux, Apple Silicon macOS, and Intel
  macOS release outputs evaluate from one flake.
- Pinned the Autobahn image by digest and used Deno's native process API so the
  compliance runner has no runtime JavaScript dependency graph.
- Run the Autobahn container with the invoking POSIX UID/GID so generated
  reports remain replaceable across repeated local runs.
- Disabled BoringSSL's unused test/benchmark targets in the embedded build and
  passed the selected Ninja executable directly to every CMake configure.

### Fixed

- Fixed connection-pool initialization, double release, stale-slot reuse, and
  inactive-slot sweeping defects. Pool reuse now waits for outstanding read,
  write, and close completions.
- Fixed application teardown leaks across sockets, TLS objects, timers,
  message storage, write storage, and pub/sub state.
- Fixed a high-severity use-after-free where application teardown could free
  the connection slab, timers, event loop, and I/O buffers while libxev
  completions still retained pointers into them.
- Fixed a recurring io_uring timer rearm that reused an expired absolute
  deadline and could spin a CPU core.
- Fixed benchmark candidate and baseline builds running from the parent
  workspace where Zig could not discover either checkout's `build.zig`.
- Fixed drained TCP write rings retaining a tail offset that split later small
  responses across the wrap boundary and triggered delayed-ACK stalls.
- Added bounded benchmark build retries for transient immutable dependency
  fetch failures.
- Fixed HTTP request accumulation, pipelining, partial writes, close-after-drain,
  duplicate framing headers, oversized metadata/body handling, and response
  header injection. Empty header names, invalid chunk-size grammar, oversized
  trailers, invalid response statuses, and bodies on 204/304 are rejected.
- Fixed WebSocket masking, fragmented empty-final frames, fragmented large
  messages, invalid UTF-8 across frame boundaries, invalid close payloads,
  unbounded writes, and masked server output.
- Fixed plaintext handling in HTTPS mode and bounded the TLS BIO pair.
- Rejected sockets now close immediately before any I/O registration, avoiding
  completion-storage exhaustion.
- Removed the per-connection chunk scratch buffer and its 8 KiB chunk ceiling;
  chunk parts now enter the bounded output ring directly.
- Fixed outbound WebSocket UTF-8, control-length, close-code, and close-reason
  validation, including the RFC 6455 distinction between protocol errors and
  invalid UTF-8 close reasons.
- Fixed compressed fragmented messages, RSV1 validation, malformed extension
  alternatives, compressed expansion bombs, and negotiated small-window
  server output.
- Separated inbound and outbound compression scratch so a drain callback or
  pub/sub send cannot overwrite a fragmented compressed message in progress.
- Closed TCP descriptors when listener binding or activation fails.
- Fixed HTTP/3 header ordering, duplicate pseudo-headers and content lengths,
  URI target and authority validation, connection-specific metadata,
  request-body and trailer framing, bounded response buffering, packet
  ownership, global lsquic initialization lifetime, and an lsquic boundary
  defect that promoted application header errors to connection aborts.

### Security

- Added strict WebSocket handshake validation for method, upgrade tokens,
  version, unique key headers, and optional application authorization.
- Added finite limits for every peer-controlled HTTP and WebSocket buffer used
  by the public server path.
- Reject ambiguous HTTP framing and control characters in response status or
  header metadata.
- Added strict HTTP/3 pseudo-header, lowercase-name, connection-metadata,
  content-length, QPACK storage, request-body, response, and UDP packet bounds.
- Added sanitizer CI with leak detection across the connection slab,
  completion-driven teardown, compression engines, and C/C++ FFI boundaries.
- Added strict RFC 7692 negotiation and no-context-takeover so compressed state
  is never retained across application messages.
- Decline offers that require an 8-bit server compression window while
  accepting 8-bit client streams only through bounded decoding. Centralized
  regressions cover both branches.
- Added libFuzzer ABI coverage at the HTTP framing, WebSocket masking, and QUIC
  packet/varint trust boundaries.

### Breaking changes

- Route and WebSocket registration return errors and must be called with
  `try`, `catch`, or equivalent handling.
- Route registration returns `error.RoutesLocked` after `listen` or
  `listen_udp` succeeds.
- Applications that need messages larger than 16 KiB must use
  `ConfiguredApp` and set matching `WsBehavior` limits.
- Output can now return `error.WouldBlock`; WebSocket producers should resume
  from the `drain` callback.
- `WebSocket.send` rejects continuation opcodes because the public API emits
  complete final messages. `send_close` closes the transport after the close
  frame drains; use `terminate` for an immediate close.
- `http3_available` is now true. `init_http3` creates transport-isolated
  HTTP/1.1 and HTTP/3 TLS contexts, and HTTP/3 servers must call `listen_udp`
  before `run`.
- `WsBehavior` now exposes `.compression`; its default remains `.disabled`.
- Request route matching uses `Request.path`; the original request target and
  query are available separately as `Request.target` and `Request.query`.

### Known limitations

- HTTP/2 WebSocket extended CONNECT is not advertised. WebSocket upgrade,
  compression, and message state remain on the HTTP/1.1 connection path.
- The live HTTP/3 server handles bounded request/response streams and passes
  the curl/ngtcp2 and aioquic gate. RFC 9220 extended CONNECT, server push,
  and WebTransport are protocol helpers only because the pinned lsquic 4.9.3
  backend lacks the required current wire interfaces. TLS 0-RTT is rejected.
- `webtransport` implements draft-ietf-webtrans-http3-16 wire semantics and
  must not be presented as live WebTransport support. RFC 10008 is the separate
  HTTP `QUERY` method implemented by the router.
- C async tokens are event-loop-confined, generation-checked, and exactly once;
  middleware remains synchronous and fixed at 32 callbacks.
- RFC 7692 deliberately requires no-context-takeover and declines offers that
  require an 8-bit server compression window. An 8-bit client window remains
  supported for bounded decompression.
- Only POSIX targets are supported. The published matrix covers Linux and
  macOS; FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD are accepted by the build
  but are not published artifacts. Windows is intentionally unsupported.
- The no-exclusion Autobahn run covers all 517 selected cases with 514 `OK`
  and 3 `INFORMATIONAL` results for both protocol and close behavior. The
  compliance gate passes groups 1-7 and 9-13, including compression.
