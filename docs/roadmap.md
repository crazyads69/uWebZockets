# Roadmap and Boundaries

This page is the honest map of what µWebZockets does, what it deliberately does
not do, and why. It exists so a developer can decide whether a missing feature
is a defect, a scoped decision, or pending work.

## Closed in 1.7.0

| Boundary | Resolution |
| --- | --- |
| No client API | Bounded HTTP/1.1 client over TCP and TLS with fixed slots, timeouts, and loopback tests ([client.md](client.md)) |
| No mutual TLS | `init_https_mtls` with `none` / `optional` / `required` verification against a caller CA bundle ([tls.md](tls.md#client-certificates-mtls)) |
| No auth or rate limiting | `middleware.Auth` (Basic/Bearer, constant-time) and `middleware.RateLimit` (fixed token buckets, rotation-resistant) ([http.md](http.md#middleware)) |
| No graceful shutdown helper | `App.catch_shutdown_signals()` and `Cluster.catch_shutdown_signals()` for SIGINT/SIGTERM and Windows console control |
| HTTP/2 and HTTP/3 were invisible in the dev log | One `http_request` record per completed exchange on both, plus HTTP/2 counter increments |
| Docs could drift | `scripts/check_docs.sh` validates every relative markdown link in CI |
| Stale supported-version policy | [SECURITY.md](../SECURITY.md) tracks the latest released minor line |
| Monolithic protocol documentation | Split into [http.md](http.md), [http2.md](http2.md), [quic.md](quic.md), [websocket.md](websocket.md), and [json_rpc.md](json_rpc.md) |

## Closed in 1.9.0

The 1.9.0 milestone closes or re-declares every limit from the 1.8.5/1.8.9
declared-limits handoff. The full measurement record is in
[`benchmarks/results/h2_tls_scaling_v1/2026_10_19/`](../benchmarks/results/h2_tls_scaling_v1/2026_10_19/README.md).

| Limit | Resolution |
| --- | --- |
| L1a No 256/1,024-connection H2-over-TLS run | Closed with the full 64-2,048 sweep on the repository host. The 4-worker TLS cluster completed 30/30 samples with zero failures; 1,024 connections reached 276,534.80 req/s at one stream and 669,300.80 at eight. Artifacts and host caveats are linked above |
| L4 MemorySanitizer scope | Closed as Option A: the dependency-boundary smoke is the permanent contract, dated 2026-10-19 ([CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md#memorysanitizer-contract-permanent-2026-10-19)) |
| L5 `Cluster.request_shutdown` after `deinit` | Closed docs-only with an explicit internal guard, a call-site doc comment, and a regression test; no public getter was added ([ADR 0003](adr/0003-tls-cluster-operational-boundaries.md)) |
| L6 TLS credential rotation | Closed as a dated decision: rolling restart remains the supported path; no hot reload ([ADR 0003](adr/0003-tls-cluster-operational-boundaries.md)) |
| L7 Backend stickiness and internal `xev` | Closed as a dated decision: selection is process-sticky, `xev` stays internal, and backend introspection needs an ADR ([architecture.md](architecture.md#event-loop-and-completions)) |
| L8 Shared-port TLS test flake | Closed after repeated focused and full-suite runs stayed green; the eight-reservation scheme remains |
| L9 Cross-worker session resumption | Closed as measured and accepted for the target workload: 1 worker reused 100/120 handshakes, 4 workers reused 23/120, which is the expected per-worker ticket behavior ([ADR 0003](adr/0003-tls-cluster-operational-boundaries.md)) |
| L10 HTTP/2 window tuning | Closed as measured, not needed: the sweep showed worker-count scaling and no timeout, failure, or write-queue stall; no window constants changed |
| L12 Post-merge provenance | v1.8.9 tag `v1.8.9` exists at `2573661d12e573d00ed0036736a68d34955c1339`, `main` is green, and a clean-clone test with an empty cache is archived. The v1.9.0 tag remains maintainer-owned after merge |

## Re-declared in 1.9.0

| Limit | Dated reason and restoration criterion |
| --- | --- |
| L1b HttpArena `baseline-h2` | The adapter and official `/benchmark` run live in `MDA2AV/HttpArena`, which this repository cannot modify or trigger. Restore only after an adapter PR uses the public cluster API, a released tag works from a clean dependency cache, and the official run saves fresh nonzero 256/1,024-connection results |
| L3b / L13 Windows runtime | The auditable libxev accept overlay and the queued-completion submit-before-cancel fix landed, and `windows.yml` now has a native `zig build test --summary all` job. Windows becomes officially supported when that job is green for the release commit; until then the compile gate remains the claim ([ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md)) |
| L11 H2/TLS benchmark in GitHub Actions | Deliberate exclusion: shared runners cannot satisfy the quiet-host evidence contract. The contract stays out of `benchmark.yml`. A future dedicated quiet runner may add a non-gating `workflow_dispatch` job that uploads raw artifacts and never compares its numbers to shared runners |

## Deliberate boundaries

These are decisions, not omissions. Each has a reason and, where relevant, the
condition that would change it.

| Boundary | Reason |
| --- | --- |
| TLS 1.2 is not supported | TLS 1.3-only is a deliberate security posture; adding 1.2 would re-enable obsolete cipher suites for no functional gain |
| No dynamic capacity overflow | Fixed startup slabs are the architecture. Exhaustion returns a structured error; silently allocating would reintroduce heap behavior on the hot path |
| Request bodies are buffered, not streamed to handlers | Handlers are synchronous; true upload streaming needs an async body-reader contract. Response streaming already exists (`begin_stream`) |
| HTTP/2 server push is not implemented | Deprecated in practice and removed from lsquic upstream; no browser consumes it |
| h2c Upgrade is not implemented | RFC 9113 removed the Upgrade mechanism; cleartext HTTP/2 uses prior knowledge and TLS uses ALPN |
| HTTP/2 caps at 8 concurrent streams and one WebSocket tunnel per connection | Stream and tunnel storage is connection-owned and carved from the slab. Raising the defaults requires specializing the connection type |
| WebTransport is not live | The pinned lsquic build exposes raw datagrams but not extended CONNECT, server-initiated unidirectional streams, or reset-at; see [ADR 0001](adr/0001-http3-datagram-and-webtransport.md) |
| HTTP/3 does not advance the metrics registry | The engine has no registry handle without new plumbing through the transport; records are emitted instead |
| kTLS is a standalone helper, not an integrated offload | The pinned BoringSSL has no kernel-TLS support, so the connection path cannot hand keys to the kernel. `uz.ktls` remains available to applications that manage their own records |
| MemorySanitizer does not instrument Zig code | Permanent decision dated 2026-10-19: Zig 0.16 emits no MSan instrumentation, so the MSan gate covers the pinned C/C++ dependency boundary ([CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md#memorysanitizer-contract-permanent-2026-10-19)) |
| BSD targets have no runtime CI | No hosted GitHub runners exist for the BSDs; the shared build graph is compiled but not executed in CI |
| Windows runtime is gated on native CI | The accept overlay and queued-close fixes landed in 1.9.0 and the workflow now runs the test suite, but official support starts only when that job is green for the release commit; see [Windows runtime blocker details](#windows-runtime-blocker-details) and [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md). No Windows binaries are published |
| macOS workers are unpinned | The platform exposes no hard-affinity API |
| The client is HTTP/1.1 only | It is deliberately small: no DNS resolution (numeric addresses only), no redirects, no cookies, no proxy support, no connection pooling, no mTLS, and no HTTP/2 or HTTP/3 client |
| The C ABI is a high-level subset | Opaque handles and fixed capacities target C/C++ consumers; the low-level HTTP/2, HPACK, HTTP/3-extension, WebTransport, UDP, and client modules are Zig-only |
| Zig 0.16.0 is the only supported toolchain | It is the latest usable release without known breaking defects for this codebase. Pre-1.0 toolchains churn; pin the exact compiler |

## Windows runtime blocker details

A native Windows runtime gate was attempted on `windows-2025` and traced to two
defects, in order of encounter.

1. **libxev accept lifecycle (upstream).** After a successful `AcceptEx`, the
   IOCP backend returns the accepted socket from the completion but never
   clears `op.accept.internal_accept_socket`. A persistent accept loop re-arms
   the completion, and `start_completion` calls `AcceptEx` again with the
   already-connected socket, which returns `WSAEINVAL (10022)`; libxev then
   panics while mapping that unmapped Winsock code to `Win32Error`. A
   standalone probe confirmed the `AcceptEx` arguments are fine (a zero
   local-address length returns `WSA_IO_PENDING` on `windows-2025`), and a
   local patch that clears the field after taking the socket got the server
   past the panic. The minimal upstream fix is to null the field on both the
   success and error paths of the accept completion.
2. **Queued completions on the Windows close path (this project).** With the
   accept fix applied, `verify_shutdown` failed with `ShutdownIncomplete`
   because a connection stayed in the pool with `is_writing = true`.
   `Completion.state()` maps both `.adding` (queued, not yet submitted) and
   `.active` to `.active`, so the Windows close branch never clears
   `is_writing`/`read_active` for a completion that is canceled before
   submission. libxev marks the unsubmitted target `.dead` and fires only the
   cancel callback, so the write callback never runs and the slot is never
   released. The fix direction is to distinguish queued from submitted
   completions (submit them before canceling, or track submission explicitly)
   and clear the flags for completions whose callback will never fire.

The 1.9.0 work carries the upstream accept fix as an auditable overlay rather
than a fork or a package-cache edit, and it submits queued IOCP completions
before canceling them so the target callback clears `read_active`/`is_writing`.
`windows.yml` now runs the full test suite on `windows-2025` in addition to the
compile gates, and a regression test closes a queued write before submission
and asserts that the pool slot returns. The decision, patch, and rollback path
are recorded in [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md).
The TLS cluster test plumbing already binds `getsockname` and `SO_RCVTIMEO`
through ws2_32, so those tests execute rather than skip. Windows remains
compile-only in the support claim until the native job is green for the release
commit.

## Near-term direction

Candidates for the next minor releases, in rough dependency order:

1. **WebSocket client** over the existing client transport, using the zslay
   client role for framing and masking.
2. **Incremental request bodies** for HTTP/1.1: a bounded, async body reader
   that lets large uploads bypass `max_body_size` per connection.
3. **Configurable HTTP/2 stream and tunnel counts** through connection-type
   specialization.
4. **HTTP/3 counter parity** by threading the metrics registry into the engine.
5. **WebTransport activation** behind the capability gate recorded in
   [ADR 0001](adr/0001-http3-datagram-and-webtransport.md), once the pinned
   lsquic exposes the required server interfaces.
6. **kTLS integration** if BoringSSL gains a supported key-handoff API.

## How to influence the roadmap

Open an issue describing the use case, or a pull request following
[CONTRIBUTE.md](../CONTRIBUTE.md). The project accepts additive changes that
preserve bounded behavior; proposals that add unbounded allocation to the hot
path or weaken a compliance gate are declined by policy, not by preference.
