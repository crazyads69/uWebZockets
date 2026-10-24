# Architecture

µWebZockets is a transport-agnostic Zig 0.16.0 server library built around one
idea: every byte of I/O and protocol state lives in a bounded, startup-allocated
slab, and no thread ever touches another thread's slab. This document covers the
runtime architecture. See [memory_model.md](memory_model.md) for allocation and
capacity details and [protocols.md](protocols.md) for wire behavior.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are small functions with explicit input and output
   state. Stateful I/O stays localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. Non-blocking I/O (epoll, io_uring, kqueue, and IOCP via libxev) drives
   callbacks. Zig's C and C++ toolchain compiles the vendored BoringSSL,
   lsquic, libdeflate, and zlib sources from pinned packages.
5. WebSocket masking operates on native SIMD vectors before handling the
   scalar tail.
6. Cross-thread data movement is lock-free. Producer and consumer state occupy
   separate cache lines.

## Shared-nothing workers

`App.cluster(worker_count)` builds a thread-per-core group. Each worker:

- allocates its own contiguous slab (pool, request buffers, WebSocket message
  regions, response write queues, optional compression scratch);
- runs its own `libxev` event loop on its own thread;
- binds the shared port with `SO_REUSEPORT`, letting the kernel load-balance
  incoming connections across listeners;
- is pinned to a distinct physical core where the platform provides a
  hard-affinity API;
- when TLS is enabled with `Cluster.enable_https` or
  `enable_https_ephemeral`, creates and owns its own BoringSSL `SSL_CTX`
  before listening and creates one `SSL` per accepted connection from it.

No connection state, request buffer, queue, completion, or mutable TLS state is
shared between workers. An accepted connection lands wholly inside the
accepting worker's slab and is only ever touched by that worker's event loop.
TLS contexts are created before the first listener starts, so handshakes,
sessions, and credential state stay confined to the owning loop.

The compiled `worker_count` is a capacity, not a hard runtime cap. A process may
select fewer active workers with `ClusterOptions.worker_count`, or use
`build_cluster_from_environment` to read `UWEBZOCKETS_WORKERS` and default to
the platform CPU count. Only active workers allocate slabs, inboxes, and thread
handles, so a large capacity does not reserve memory for unused workers.
`worker(2)` is how you check that a two-worker cluster exposes exactly two
workers. Pinning is physical-core based; a logical-CPU default may oversubscribe
SMT hosts when affinity is enabled.

```text
               SO_REUSEPORT
                    |
     +--------------+--------------+
     |              |              |
     v              v              v
 worker 0       worker 1       worker 2        (one OS thread each)
 loop + slab    loop + slab    loop + slab
 pinned CPU 0   pinned CPU 1   pinned CPU 2
     |              |              |
     +------ lock-free inbox ------+          (cross-worker publish only)
```

### CPU affinity

`src/core/affinity.zig` selects one representative CPU per physical core:

- Linux reads `sched_getaffinity` for the allowed set, then
  `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list` to skip SMT
  siblings. Worker `i` is pinned with `sched_setaffinity`.
- Windows reads the process affinity mask and calls `SetThreadAffinityMask`.
- Other platforms report `error.UnsupportedPlatform` and continue unpinned;
  macOS has no hard-affinity API.

Pinning is best effort. A restricted cpuset or a failed syscall logs once and
leaves the worker unpinned rather than refusing startup. Extra workers beyond
the physical core count wrap over the selection instead of floating freely.

### Lock-free coordination

Cross-worker publish uses a bounded Vyukov sequence ring per worker inbox
(`src/router/cluster.zig`). Any worker thread may publish; only the owning
worker consumes on its event loop. The queue is allocation-free, reports
`error.ClusterQueueFull` instead of blocking, and keeps the enqueue and dequeue
positions on separate cache lines to avoid false sharing.

After removing the former spinlock, no mutex or spinlock remains on the
steady-state I/O path. The only lock left in the tree is lsquic's process-wide
initialization reference in `src/quic/lsquic_api.zig`, which is touched before
the first listener starts and after the last one drains.

### TCP tuning

Listeners and accepted sockets are tuned per platform:

- Linux listeners set `TCP_DEFER_ACCEPT` so the event loop is not woken by the
  three-way handshake alone; it wakes on the first application byte.
- Linux accepted sockets request `TCP_QUICKACK` once at accept, removing the
  initial delayed-ACK stall without adding a syscall to the read path. The flag
  is one-shot by design, so throughput-sensitive deployments keep it confined
  to connection setup.
- Other kernels keep their default accept and ACK policy.

### Windows fallback

Windows now runs the test suite on a native runner. The 1.9.0 accept overlay
and queued-close fix remove the blockers recorded in
[roadmap.md](roadmap.md#windows-runtime-blocker-details) and
[ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md); official support
follows a green runtime job for the release commit. Windows IOCP already
multiplexes completions across threads and has
no `SO_REUSEPORT`. In cluster mode every worker binds the shared address with
`SO_REUSEADDR` instead. Each accepted connection still lands wholly inside the
accepting worker's slab, so routing stays safe; kernel distribution across
listeners is unspecified and the Windows cluster is documented as a graceful
fallback rather than a load-balancing path. Affinity uses the native
`SetThreadAffinityMask` call.

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
                                      |                       +--> per-worker gzip pool
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

On Linux, equal-sized lsquic packets for one destination are submitted with one
`sendmsg` carrying `UDP_SEGMENT` (GSO). Mixed sizes or destinations fall back to
the per-packet path. Receive-side `UDP_GRO` remains disabled until the loop can
read ancillary segment boundaries; feeding a coalesced buffer to lsquic without
them would corrupt short-header parsing.

## Listeners and the startup barrier

`App.listen` binds one TCP endpoint. `App.listen_all` accepts up to four
endpoints, binds all of them without arming an accept, verifies each local port,
and only then arms every accept completion. A failure closes the sockets created
by that call and leaves routes unlocked. Each endpoint may select TLS
independently, but all TLS listeners share the application's certificate and
client-auth policy. The barrier is in-process and all-or-nothing; cross-process
socket takeover is a later milestone.

## Event loop and completions

`src/core/loop.zig` wraps one libxev loop with 4096 completion entries and runs
it `.until_done`. All completions are inline members of their owning connection,
server, transport, or engine; none is heap-allocated, and none outlives the
storage it borrows. Only `loop.zig` inspects the libxev backend; every other
module cancels through the backend-aware shim. Dependency provenance follows
[dependency_forks.md](dependency_forks.md): libxev pins `cbf01bc` on
`uwz/zig-0.16`, lsquic pins `85bd081c` on `uwz/main`, and the h1spec submodule
pins `999ba9e8`. The former [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md)
overlay and the local lsquic/h1spec patches are removed.

`src/core/xev.zig` re-exports libxev's runtime-selectable API and registers it
as the package's `xev` import. On Linux the loop probes io_uring first and
degrades to epoll when the kernel or a container seccomp policy rejects the
ring, so the server still starts on Docker Desktop and OrbStack without
privileges; other targets keep libxev's static single-backend API. Dynamic
backend selection is process-global: the first loop selects it exactly once and
later loops reuse that selection, and an attempted backend change fails with
`error.BackendChanged` instead of mixing epoll and io_uring loops. The
io_uring-to-epoll fallback therefore remains available only on the first loop.
This stickiness is a deliberate 2026-10-19 decision, and `xev` stays internal:
the package exports no backend type, selector, or loop handle. Adding backend
introspection to the public API requires an ADR first.
An established io_uring loop retries loop creation at most 32 times with a
1 ms delay between attempts while the kernel uncharges a closed ring
(`error.SystemResources`); any other error, backend, or exhausted attempt
bound returns the original error instead of switching backends.
epoll offloads blocking file operations to an owned thread pool, which the loop
creates and tears down around the event loop.

A closed pool slot returns to the freelist only through
`release_closed_connection` after close, read, write, and cancellation
completions have all drained. That gate prevents a stale completion from
observing a reused connection.

The registration-to-handler map for every native callback is in
[callback_lifecycle.md](callback_lifecycle.md).

## Transports

### TCP, TLS, and HTTP/1.1

Plaintext sockets detect the HTTP/2 prior-knowledge preface before parsing
HTTP/1.1. TLS uses BoringSSL with ALPN preference `h2` then `http/1.1`;
[tls.md](tls.md) covers credential loading and ephemeral development
certificates. Request bytes accumulate in the connection's bounded request
buffer, the strict parser proves completeness, and the router dispatches
through middleware to a handler.

### HTTP/2

`src/core/tcp.zig` embeds one eight-stream server session per connection and
routes decoded requests through the same middleware and sync/async handlers as
HTTP/1.1. The session owns its HPACK table, per-stream request/body/response
storage, and async tokens. SETTINGS, PING, GOAWAY, RST_STREAM, trailers,
partial DATA, and connection/stream flow control are handled without dynamic
allocation. RFC 8441 WebSocket tunneling is supported through extended CONNECT;
one connection permits one active tunnel.

### HTTP/3

`init_http3` creates isolated TLS 1.3 contexts so TCP advertises `h2` and
`http/1.1` while QUIC advertises only `h3`. The adapter decodes HTTP/3
pseudo-headers directly into the existing `Request` shape and writes structured
QPACK response headers without converting through HTTP/1.1 text. QUIC
connections, streams, header sets, packet buffers, and bodies come from
startup-allocated contiguous pools. The QUIC listener keeps TLS 0-RTT
disabled, so replayable requests never reach a handler; the TCP/TLS listener
enables 0-RTT and admits safe methods only (see [tls.md](tls.md)).

Congestion control is pinned to BBRv1 with per-connection pacing so throughput
and tail latency hold up on lossy paths.

### Edge and kernel bypass

- `src/core/transport.zig` exposes a protocol-only core and a generic adapter
  driver used by the WASM edge builds.
- `wasm32-freestanding` exports linear memory for V8 isolate hosts;
  `wasm32-wasi` exports bounded `alloc`/`free` and generation-checked handles.
- `src/core/ktls.zig` configures Linux kTLS and offers zero-copy
  `sendfile`/`splice` helpers.
- `src/core/zero_copy.zig` streams static response files through `sendfile` on
  Linux and macOS. Because a blocking `sendfile` sleeps for its full count, the
  transfer opens a temporary nonblocking window over the (blocking) io_uring
  socket and closes it before any completion is queued; stalled bytes fall back
  to a bounded dribble that reuses the idle TLS staging buffer.
- `src/xdp/socket.zig` implements AF_XDP UMEM ownership rings and the TX path,
  and `src/xdp/transport.zig` exposes the bypass transport to callers that
  drive it directly. The server data path always serves through the standard
  stack: a `ServerConfig.transport = .kernel_bypass` request reports
  `.standard` with reason `.data_path_unwired` and increments
  `xdp_kernel_bypass_fallbacks` instead of claiming a bypass no accept/read
  path uses.
- `src/observability/metrics.zig` renders a fixed-capacity registry into
  Prometheus text without allocating, `src/observability/ebpf.zig` reads the
  pinned per-CPU histogram, and the `ebpf` build step emits the XDP redirect
  and latency histogram objects. Attaching the redirect, pinning the histogram,
  and populating its XSK map requires network-administration privileges.
- `src/quic/datagram_ring.zig` and `src/router/datagram.zig` route WebTransport
  datagrams by session path into per-connection SoA rings carved from the
  startup slab.
- `src/core/timer_wheel.zig` is the per-worker deadline engine: four levels
  (256 x 1 ms, 64 x 256 ms, 64 x 16.4 s, 64 x 17.5 min) with intrusive nodes
  embedded in pooled connections. `src/core/timer.zig` drives it with one
  persistent libxev timer that wakes on a bounded five-millisecond tick while
  deadlines exist. Keep-alive, incomplete-header, and deferred response
  deadlines share that timer; there is no periodic pool sweep. The 5 ms tick
  is the safe cross-backend choice on IOCP, where resetting or canceling and
  reusing the same timer completion races queued callbacks. Shutdown lets the
  final tick disarm instead of canceling.

### Client

`src/client/` mirrors the server's design rather than reusing its connection
type: one `client(N)` value owns its own libxev loop and `N` request slots,
each with embedded connect, read, write, close, and timer completions. A slot
returns to the free list only after every cancel and the socket close have
drained, exactly like the server's `release_closed_connection` gate. The
response parser is pure and allocation-free; TLS uses the same BoringSSL
memory-BIO pattern as the server. See [client.md](client.md).

## Shutdown ordering

Shutdown reverses the ownership graph deterministically:

1. Reject new work and mark the application unavailable.
2. Stop the per-worker timing wheel and the signal watcher, close the
   listener, and shut down the UDP/QUIC transport.
3. Cancel every connection completion and run the loop until all completions
   are disarmed.
4. Verify drained state: no active pool slots, a completed listener close, and
   an empty QUIC transport.
5. Release TLS state, QUIC state, the loop, and the slab through the original
   allocator.

Applications opt into signal-driven shutdown with `App.catch_shutdown_signals()`
before `run`. On POSIX the watcher installs SIGINT and SIGTERM handlers that
write one byte into a non-blocking self-pipe; the read end is polled by a libxev
file completion, so the callback runs on the loop thread and signals that
arrive before the loop drains coalesce into one shutdown request. Windows
installs a console control handler that sets a process flag and wakes a libxev
async. `begin_shutdown` stops the watcher through the same arm the handler uses
instead of canceling a completion, and `deinit` restores the previous
dispositions and closes the pipe only after the loop has drained.

`deinit` asserts drained state instead of guessing and panics if called from
inside the event loop.
