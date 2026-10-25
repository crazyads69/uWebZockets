# 0007. Cluster lifecycle, failure reporting, and release claiming

- Status: Accepted
- Date: 2026-10-25
- Deciders: router/API, transport/runtime, verification
- Release: 2.1.5

## Context

The thread-per-core `Cluster` exposed workers but not its own lifecycle. A
supervisor could not tell a configured group from a stopped one, and
`Cluster.run` collapsed every worker event-loop failure into
`error.ClusterWorkerFailed`. With several workers, that lost the failing index
and the original error, leaving only a log line. `Cluster.publish` returned a
count but did not distinguish accepted workers from full inboxes or failed
loop wakeups.

ADR 0003 rejected a public lifecycle getter without a new decision record. The
2.1.5 API-hardening release adds that record and keeps the existing shutdown
contract: `request_shutdown` after `deinit` remains a documented no-op.

## Decision

### Five-state lifecycle

`Cluster.state()` returns a `ClusterState` backed by an atomic value:

| State | Meaning |
| --- | --- |
| `configured` | Workers are allocated; no thread has started |
| `running` | Worker threads are running or draining |
| `stopped` | `run` returned after every worker joined |
| `releasing` | One `deinit` owner is freeing storage |
| `released` | All worker and thread storage is freed |

`worker_count()` returns the active worker count. `worker_capacity()` returns
the compiled capacity. The public fields `threads`, `active_workers`,
`thread_count`, `worker_failed`, and `deinitialized` remain for source
compatibility; `state()`, `first_failure()`, and `worker_count()` are
authoritative.

`configure`, `enable_https`, `listen`, and `catch_shutdown_signals` reject a
released or releasing group with `error.ClusterDeinitialized`, an active group
with `error.ClusterRunning`, and a finished group with
`error.ClusterStopped`. `run` uses the same names for re-entry. Re-running a
drained group is not supported; build a new group instead.

### Atomic run and release claims

`run` claims the configured-to-running transition with a compare-and-swap.
A second concurrent `run` returns `error.ClusterRunning`. `deinit` claims the
configured-or-stopped-to-releasing transition with a compare-and-swap before it
frees anything. A second concurrent `deinit` observes `releasing` or
`released` and waits for the winner to publish `released` before returning.

`cleanup_workers` stops the watcher and drains every worker loop before the
group publishes `stopped`. If the drain fails, the watcher survives `stopped`
and `deinit` releases it after the loops are destroyed, so the free path is
still safe but the release is not completed before the terminal state.

Supervisor calls that touch worker storage register an in-flight call before
the lifecycle check. The increment, lifecycle load, release CAS, and idle load
use SeqCst so the store-load handshake is a total order on weakly ordered
targets, not only on x86. `deinit_checked` claims `releasing` through
`begin_release` and then waits for calls that entered before the claim; a call
that enters after the claim sees `releasing` or `released` and returns without
touching worker storage. The counter lives in the cluster object, which
outlives the worker arrays, so the losing path cannot use freed memory. A
`configure` callback must not call `run` or release; that call already holds a
registration and release would wait on it.

### Failure reporting

A spawn failure records `FailurePhase.spawn`; a worker event-loop failure
records `FailurePhase.run`; a post-run drain failure records
`FailurePhase.cleanup`. All retain the worker index and original error.
The first failure wins so a shutdown cascade does not replace the root cause;
`failure_count()` reports the total. `first_failure()` remains available after
`run` returns.

The failure record uses a spin lock held only on the cold failure and read
paths. The steady-state request path remains lock-free.

### Publish outcome

`publish_report()` returns `PublishReport`:

- `queued`: inboxes that accepted the message;
- `dropped`: inboxes that were full;
- `notify_failed`: accepted messages whose loop wakeup failed or was suppressed
  during shutdown;
- `first_dropped_worker`: the first full inbox index, when any.

`attempted()` returns `queued + dropped`; `all_delivered()` is true only when
`dropped` and `notify_failed` are zero. `publish()` keeps its `!usize` shape
and returns `report.queued`; after `run` it returns `ClusterStopped`. Message
validation runs once before any inbox is mutated, so an invalid topic or
oversized payload cannot partially deliver.

### Worker thread manager

Lifecycle transitions, release claiming, borrowed thread-slice start/join
coordination, and first-failure capture live in `src/router/worker_group.zig`.
Thread storage stays in `Cluster.threads`; the group never allocates and never
owns worker slabs, inboxes, TLS state, or loops. The group is an implementation
detail. Zig has no private fields, so `Cluster.group` is reachable; direct
access is unsupported and can corrupt lifecycle invariants. `Cluster` methods
are the contract, and the group is not exported from `src/root.zig`.

### Typed configuration callback

`Cluster.configure` accepts the named `ConfigureCallback` function pointer with
a `comptime` parameter instead of `anytype`. Concrete route-configuration
functions keep compiling because their error sets coerce to `anyerror`; a
generic `anytype` route function must be specialized to the concrete `Worker`
type because it cannot coerce to a function pointer.

### Checked release

`deinit_checked()` returns `error.ClusterRunning` while `run` is active and
claims release once: a later call waits for the winning owner to publish
`released`. `deinit()` keeps its existing signature and panics on
`error.ClusterRunning` for compatibility.

## Alternatives considered

- **Keep the boolean `worker_failed` flag**: rejected because it cannot report
  the worker index, phase, or original error to a supervisor.
- **Return only the last failure**: rejected because a shutdown cascade would
  overwrite the root cause.
- **A plain lifecycle enum**: rejected because supervisors may read it while
  `run` is active; the state is atomic instead.
- **No release claim**: rejected because concurrent `deinit` could free worker
  storage twice.
- **Own the thread slice in the group**: rejected because it retypes the public
  `Cluster.threads` field in a patch release. The group borrows the slice.
- **Expose a general-purpose worker pool**: rejected because the framework's
  threading model is thread-per-core cluster workers, not a task pool.
- **Panic on publish after `run`**: rejected because a supervisor should receive
  a typed error, not a process abort.
- **Restart a stopped cluster**: rejected because the worker slabs have already
  drained and several registrations borrow process-lifetime state.

## Consequences

- Existing `configure`, `publish`, `listen`, TLS, field access, and shutdown
  call sites keep working. Only misuse after `run` now returns a specific error
  instead of silently queueing into loops that no longer consume.
- `ClusterState`, `WorkerFailure`, `FailurePhase`, and `PublishReport` are
  available through `src/root.zig`.
- `Cluster.deinit` still panics if the group is running; `deinit_checked`
  covers supervisors that need a typed result.
- The public shutdown no-op after `deinit` from ADR 0003 is unchanged.

## References

- `docs/api.md` cluster section.
- `docs/architecture.md` shared-nothing workers.
- ADR 0002 and ADR 0003.
- `src/router/worker_group.zig`, `src/router/cluster.zig`, and
  `src/router/app.zig` (`Cluster`).
