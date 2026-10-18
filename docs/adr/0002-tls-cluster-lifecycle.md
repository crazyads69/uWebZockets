# 0002. TLS-enabled TCP cluster lifecycle

- Status: Accepted
- Date: 2026-10-18
- Deciders: router/API, crypto/TLS, transport engineering
- Release: 1.8.5

## Context

The 1.8.0 API offered `init_https` for one TLS application and
`build_cluster` for a plaintext shared-nothing worker group, but no supported
way to give each worker its own TLS context before the group bound its shared
port. HttpArena's `baseline-h2` profile therefore ran on a single application
loop and fell from ~153k requests/s at 256 connections to zero at 1,024
connections, and the profile was withdrawn rather than benchmarked through
private fields or adapter glue. The hardening handoff (Candidate E) requires a
released, additive API with per-worker TLS ownership, deterministic cleanup,
documented ordering, and no per-request locking, while `init_https`,
`init_http3`, and existing cluster semantics stay unchanged. The same handoff
requires a decision record with mechanism, memory and API impact, rollback, and
a benchmark cohort with acceptance thresholds.

## Decision

Add two methods to the type returned by
`Server.builder(...).build_cluster(allocator, worker_count, options)`:

- `Cluster.enable_https(cert_path, key_path)` loads one BoringSSL context per
  worker from PEM files.
- `Cluster.enable_https_ephemeral()` generates one self-signed P-256 context
  per worker for development.

Supported order: `build_cluster` -> `configure` -> `enable_https` once ->
`listen` -> `run` -> `request_shutdown` or a signal -> `deinit`. Workers keep
using the existing accept path, which creates one `SSL` per connection from the
worker's own context; ALPN keeps advertising `h2` ahead of `http/1.1`, so the
same API serves HTTP/1.1-over-TLS and HTTP/2-over-TLS.

`install_worker_tls` is all-or-nothing: it releases exactly the contexts the
call created when any worker fails, leaves pre-existing contexts untouched, and
leaves the group retryable. `App.release_tls` makes context release idempotent,
so `deinit` releases every context exactly once on every path. Illegal order
reports `error.ClusterDeinitialized`, `error.ClusterRunning`,
`error.AlreadyListening`, or `error.TlsAlreadyEnabled`; credential failures
come from `TlsContext.init`.

The change also fixes a pre-existing transport defect found while validating
the worker group: libxev's dynamic API dispatches through one process-global
backend, so the event loop now selects that backend exactly once per process
(`src/core/loop.zig`). The io_uring-to-epoll fallback remains available only
while the first loop is created; after selection, a forged backend change fails
with `error.BackendChanged` instead of mixing epoll and io_uring loops.

### Scope boundaries

- TCP/TLS clustering only. QUIC/H3 clustering is not supported: connection
  routing, retries, and connection IDs have different semantics, and a TCP TLS
  cluster does not imply a QUIC one.
- No mTLS on the cluster API; single-application `init_https_mtls` remains.
- `enable_https` is startup-only; credentials are read once per worker, so
  rotation requires a rolling restart.

## Alternatives considered

- **TLS-aware cluster builder** instead of methods: rejected because a new
  builder variant duplicates `ServerConfig` and makes the enable-before-listen
  rule less obvious than an explicit call between `configure` and `listen`.
- **One shared `SSL_CTX` for all workers**: rejected. BoringSSL contexts are
  safe to share for `SSL_new`, but sharing would introduce cross-thread
  session/ticket state, contradict the shared-nothing contract, and make
  per-worker credential errors and rollback indistinguishable.
- **Adapter-side TLS setup or a private API**: rejected by the handoff
  boundaries; the capability must exist in a released library version.
- **Fixing H2 capacity by capacity presets alone**: rejected as the first step;
  the observed failure was the single-loop execution model, not slab sizes.

## Expected mechanism and impact

- Mechanism: `worker_count` independent accept loops each terminate TLS on the
  shared `SO_REUSEPORT` port, replacing the single-loop TLS listener. Cache and
  allocator behavior mirror the plaintext cluster.
- Memory: +1 `SSL_CTX` per worker (order of tens of KiB), allocated outside the
  startup slab; `slab_bytes()` is unchanged and the request path stays
  allocation-free and lock-free.
- API: additive only. `init_https`, `init_https_ephemeral`, `init_https_mtls`,
  `init_http3`, `init_http3_ephemeral`, `build_cluster`, and existing cluster
  method signatures are unchanged.
- Rollback: stop calling the new methods; no default behavior changes. The loop
  fix should not be rolled back independently, because per-loop detection was
  the mixed-backend defect.

## Benchmark cohort and acceptance thresholds

- Cohort: HttpArena `baseline-h2` at 256 and 1,024 connections against the
  released tag, built from a clean dependency cache, alternating with the
  existing plaintext and h2c rows on the same host.
- Thresholds before restoring the profile subscription: both connection levels
  complete with nonzero requests/s and only expected success statuses; no
  systematic broken-pipe or disconnect pattern; CPU and p99 are reported next
  to plaintext and are not worse in kind; results are saved by the official
  run. Library-side gates in this release: Debug suite, ReleaseSafe,
  ASan/UBSan, Windows and macOS cross-compile, package consumer, formatter,
  conventions, docs, and version metadata.
- This release makes no competitive throughput claim. The 1,024-connection
  evidence remains an HttpArena-side acceptance item; the library contribution
  is the missing public capability plus its lifecycle tests.

## Consequences

- `baseline-h2` can be restored with public APIs only, without adapter
  workarounds, once the benchmark run above succeeds.
- `Cluster` mutating methods reject use after `deinit` with
  `error.ClusterDeinitialized` instead of touching released storage.
- QUIC/HTTP/3 clustering stays explicitly unsupported and documented as such.
- Future TLS cluster work (mTLS, credential rotation, cross-worker session
  resumption) must go through a new decision record.

## References

- The repository TLS/H2 scaling handoff and performance hardening guide
  (implementation task documents, removed in this release).
- `src/router/app.zig`, `src/router/builder.zig`, `src/crypto/tls.zig`,
  `src/core/loop.zig`, `src/core/tcp.zig`.
- `docs/tls.md`, `docs/architecture.md`, `docs/memory_model.md`,
  `docs/deployment.md`.
- External: HttpArena PR `MDA2AV/HttpArena#1536` (removed `baseline-h2` rows,
  TLS CPU scaling discussion).
