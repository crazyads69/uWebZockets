# 0003. TLS cluster operational boundaries

- Status: Accepted
- Date: 2026-10-19
- Deciders: crypto/TLS, router/API, verification
- Release: 1.9.0

## Context

ADR 0002 gave each worker its own `SSL_CTX` and required a new decision record
for TLS cluster work that follows. Two operational questions remained open
after 1.8.9:

1. Credential rotation currently requires a rolling restart because
   `enable_https` reads the PEM files once per worker before `listen`.
2. Each worker owns its own session-ticket keys, so a reconnect that lands on a
   different worker cannot resume the TLS session.

Both are behavior boundaries, not defects. The 1.9.0 milestone requires a dated
decision with a restoration criterion instead of an open question.

## Decision

### Credential rotation

No hot reload is added in 1.9.0. A safe per-worker context swap needs a
generation-checked credential generation, atomic publication to the owning
loop, draining of every in-flight `SSL` that references the old context,
secure release after the last reference, and a rollback path for a bad PEM
load. No measured production requirement justifies that surface yet.

Operators continue to rotate by rolling a new process and draining the old one.
The supported order is unchanged: `build_cluster` -> `configure` ->
`enable_https` -> `listen` -> `run` -> `request_shutdown` or a signal ->
`deinit`.

Restoration criterion: a deployment requires zero-downtime rotation with a
measured reconnect or availability cost, and a new ADR records the generation
scheme, in-flight safety, failure rollback, and tests.

### Cross-worker session resumption

Cross-worker resumption is accepted as a boundary for the target HTTP
workload. `h2load` opens a fixed set of long-lived connections and does not
reconnect during a sample, so per-worker tickets do not affect the measured
request throughput. A reconnect storm still pays a full handshake whenever the
kernel distributes the new connection to another worker.

The 1.9.0 probe recorded 20 full and 100 resumed handshakes on the one-worker
control, and 97 full and 23 resumed handshakes on the four-worker cluster over
the same 20 iterations of one fresh connection plus five reconnects. No
handshake failed. The four-worker reuse rate is close to one quarter because
only a reconnect that lands on the worker that issued the ticket can resume.
Same-worker resumption works; cross-worker resumption does not share ticket
keys. Sharing them would require a cross-loop key manager, a rotation policy,
and a measured TLS-state cost, which is a larger change than this release
allows. Raw counts are archived with the other 1.9.0 measurement artifacts; the
probe is `scripts/probe_tls_resumption.sh`.

Restoration criterion: a target workload shows that reconnect handshake cost
is material, and an ADR accepts shared ticket keys with measured state and
rollback behavior.

### Backend selection and shutdown no-ops

Backend selection stays process-sticky and `xev` stays internal; see
[architecture.md](../architecture.md#event-loop-and-completions).
`Cluster.request_shutdown` after `deinit` remains a documented no-op with an
explicit guard at the call site.

## Alternatives considered

- **Atomic `SSL_CTX` swap without draining**: rejected because in-flight
  `SSL` objects hold references and per-worker arena ownership is not
  generation-aware.
- **Shared `SSL_CTX` for all workers**: rejected in ADR 0002 and still rejected;
  it would move ticket and session state across loops and weaken the
  shared-nothing contract.
- **Reload on every connection**: rejected because it puts file I/O and
  allocation on the accept path.
- **Public lifecycle getters for the shutdown no-op**: rejected because the
  behavior is already documented and a new public method needs an ADR. ADR 0007
  supersedes this for the lifecycle state; the post-release no-op stands.

## Consequences

- Rolling restart remains the production rotation procedure and is a decision,
  not a missing feature.
- Per-worker session tickets remain the accepted default for benchmark-shaped
  workloads; cross-worker resumption is a measured, documented boundary.
- A future hot-reload or shared-ticket implementation starts from this ADR and
  ADR 0002, not from an undocumented code path.

## References

- `docs/adr/0002-tls-cluster-lifecycle.md`.
- `docs/tls.md`, `docs/deployment.md`, `docs/roadmap.md`.
- `scripts/probe_tls_resumption.sh`.
- `benchmarks/h2_tls_scaling_guarantee.md` and the 1.9.0 results directory.
