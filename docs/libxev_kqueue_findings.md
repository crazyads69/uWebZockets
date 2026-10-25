# libxev kqueue findings: invalid submission state and duplicate queueing

Status: the scheduler workaround shipped in 2.1.6; XEV-003, XEV-004, and
XEV-005 are merged into `farbenbuilds/libxev` and pinned by 2.1.6.
Date of measurements: 2026-10-25. Host: macOS 26 (Darwin 25.0.0), arm64,
Zig 0.16.0, `wrk` and `h2load 1.70.0` on the same host as the server. The host
was under load during the runs (load average about 9.7, headless Chromium and
an endpoint-security daemon), so absolute throughput is lower than an idle
machine and only A/B comparisons taken in the same session are meaningful.

Pinned dependency under test: libxev `cbf01bc432a84cd91a99c1cb1031b46416d044c7`
(`uwz/zig-0.16`, XEV-001 and XEV-002). The 2.1.6 pin is
`c49f6dfb83038c146232472c063e4b2681d098d8`, which adds XEV-003 through XEV-005.

## Summary

| # | Finding | Evidence | State |
|---|---------|----------|-------|
| 1 | The scheduler `.rearm` spin starves the loop. HEAD serves 0 req/s on macOS. | `benchmark_http.sh` on HEAD: `0 requests in 10.09s`. Current tree: 50-55k req/s at 64 connections. | Fixed in 2.1.6 by the relative-tick change in `src/core/timer.zig`; the same test fails on Linux io_uring at 2.1.5. |
| 2 | libxev logs `invalid state in submission queue state=.active` under 64 concurrent connections. | Control: 12 of 28 valid server starts. | Fixed by upstream PR 245 in the scratch tree (0 of 29). |
| 3 | `queue.zig:24` assert (`v.next == null`) panics `cluster: programmatic shutdown drains the signal watcher`. | Same panic at HEAD and at the working tree. Instrumentation: `op=read state=active` pushed twice from `submit()`. | Fixed in the scratch tree by PR 245 plus a pre-`perform` duplicate guard. |
| 4 | No memory leak in the measured configurations. | RSS plateau, `leaks` reports 0, descriptors constant. | No action. |
| 5 | The 256 and 1024 connection throughput collapse of `examples/hello_world.zig` is a capacity limit, not a bottleneck. | `uz.App(128)` caps at 128 connections; profile shows the loop waiting in `kevent`. | No action. |

## Downstream status in 2.1.6

The scheduler workaround from finding 1 shipped in 2.1.6: each tick disarms the
completed timer and arms a fresh relative five-millisecond timer, and a
stopping scheduler does not re-arm. This removes the kqueue spin without
depending on a new libxev pin.

The fork fixes are merged through
<https://github.com/farbenbuilds/libxev/pull/1> at
`c49f6dfb83038c146232472c063e4b2681d098d8`, based on
`cbf01bc432a84cd91a99c1cb1031b46416d044c7`:

- XEV-003, keep a rearmed completion active after `submit()` reported it.
- XEV-004, queue a still-readable completion once before `perform()`.
- XEV-005, guard nested submits in both dispatch loops, flush staged deletes
  from `no_wait`, and balance `EV_ERROR`/non-kqueue rearm accounting.

The exact XEV-005 tree passed 65/65 macOS arm64 kqueue tests in Debug and
ReleaseSafe and 142/146 Linux tests (4 skipped). 2.1.6 pins the merge commit in
all four dependency views under [dependency_forks.md](dependency_forks.md).

## Timer timespec carry workaround

libxev's `timer_next` adds the requested nanoseconds to the cached nanosecond
field without carrying into seconds. An arm that lands in the last five
milliseconds of a second can therefore become a roughly one-second wait on
kqueue, epoll, io_uring, and IOCP. The 2.1.6 scheduler caps each relative arm
inside the current second and resumes the normal cadence on the next tick. A
fork patch that normalizes the timespec is a separate XEV-006 candidate; it is
not part of XEV-003 through XEV-005. Remove the scheduler guard when the pinned
fork carries the nanoseconds itself.

## Upstream research (read-only; upstream is fetch-only for this project)

Searched `mitchellh/libxev` for the exact log text and for kqueue rearm and
queue defects. Related items, with what each one does and does not address:

| Item | State | Relevance |
|------|-------|-----------|
| Issue 122, kqueue hits unreachable code with high completion loads | open | Same family: high concurrency on kqueue, `.no_wait` leaves pending changes. |
| Issue 169, `v.next` not cleared when re-enqueuing between queues | open | Matches the `queue.zig:24` assert seen in the cluster test. |
| Issue 105, "ghost" send callback on kqueue | open | Callback runs again after `.disarm` with 10000 connections. |
| PR 245, keep a rearmed completion active when `submit()` reported it | open | Reporter describes accept and recv completions that rearm and the exact log line `invalid state in submission queue state=.active`. Verified here. |
| PR 224, tick(0) EV_DELETE flush, rearm state, submit queue corruption | open | Does not remove finding 2 (12 of 30 hits remain with it applied). With it applied `router: timing wheel reaps a silent connection` hangs again. Not adoptable as is. |
| PR 170, clear `next` before re-enqueue | open | Hides a completion present in two queues instead of preventing it. Not recommended. |
| PR 115, overflow in the kqueue backend | merged | Not sufficient for issue 122 per its reporter. |

## Experiment 1: invalid submission state

Reproduction: start `hello_world`, run one `wrk -t2 -c64 -d2s` burst, stop the
server. Repeat with a fresh server per trial. A trial counts only when the
server logged `server listening` and `wrk` completed more than 1000 requests.
`ReleaseSafe` builds, port 3100 (a scratch copy of the example; the repository
example is unchanged).

| Build | Valid trials | Trials with `invalid state` |
|-------|--------------|-----------------------------|
| Control (current tree, unpatched libxev) | 28 | 12 |
| libxev with PR 245 applied | 29 | 0 |
| libxev with PR 224 applied (earlier run on port 3000, 30 starts, 2 refused connections, not repeated with the strict trial script) | 28 | 12 |

The logged completion was always `op=accept`. No `accept error` line was
logged in those runs, so the accept failure path is not the cause.

An earlier run on port 3000 was discarded: a `bun` process unrelated to this
project held that port, which made a "0 of 30" result meaningless. The trial
script now rejects any trial where the server did not start.

Mechanism, from PR 245's description and consistent with the measurements: when
the descriptor is already ready at submission time, `submit()` returns the
event and the callback runs from the completion queue. If the callback returns
`.rearm`, the kqueue filter stays registered but the completion is left
`.dead`, so a later start puts an active filter back on the submission queue.

## Experiment 2: duplicate queueing and the cluster test panic

PR 245 alone still panics `cluster: programmatic shutdown drains the signal
watcher`. Instrumenting each `completions.push` in `kqueue.zig` printed:

    DOUBLEQ line=267 op=read state=active

The signal watcher polls a pipe with a zero-length read. The filter is
level-triggered and still registered, so a second `kevent` return before the
callback runs enqueues the same completion twice. Skipping such an event
before `perform()` removes the panic. The guard must run before `perform()`:
for a read or an accept, `perform()` consumes data or accepts a connection,
and discarding that result would lose it.

Guard added on top of PR 245 (scratch tree only):

    const c: *Completion = @ptrFromInt(@as(usize, @intCast(ev.udata)));

    // A level-triggered filter can report the same completion again before
    // its callback ran. Skip it before perform() so a second read or accept
    // cannot consume and discard work.
    if (c.next != null or self.completions.tail == c) continue;

Full test suite results (`src/tests`, 645 tests):

| Tree | Result |
|------|--------|
| HEAD (unpatched) | `timer scheduler rearms an earlier deadline` fails, `router: timing wheel reaps a silent connection` hangs forever, signal watcher test panics. |
| Working tree, unpatched libxev | Timer tests pass. `cluster: programmatic shutdown drains the signal watcher` panics (queue assert). |
| Working tree, PR 245 only | Same panic. |
| Working tree, PR 245 plus guard | 633 passed, 10 skipped, 2 failed. |

The 2 failures also occur at HEAD and are unrelated to libxev:
`config: default slab carries the router region at the end` (expected
683382400, found 683300480) and `kernel: validate_umem accepts page-aligned
power-of-two regions` (`InvalidConfiguration`). Neither was investigated.

## Experiment 3: no regression from the patch

Alternating A/B pairs, `ReleaseFast`, `wrk -t2 -c64 -d8s`, fresh server per
run, loaded host:

| Round | Control req/s | Patched req/s |
|-------|---------------|---------------|
| 1 | 23806 | 24404 |
| 2 | 23016 | 24644 |
| 3 | 23438 | 24900 |

p99 latency ranged 43-49 ms for both. The patch is not slower.

## Experiment 4: memory

`hello_world`, `ReleaseFast`, current tree, seven consecutive wrk rounds at 64,
256 and 1024 connections:

- RSS 7.4 MB idle, 12.2 MB after the first round, 16.8 MB from the second round
  on, then flat.
- Open descriptors constant at 9.
- Idle CPU 0.0 percent.
- `leaks`: `0 leaks for 0 total leaked bytes`.

`tls_cluster` through the h2 harness, 4 workers, capacity 2048, 64
connections, nine consecutive 8 s samples: RSS 223264 KB, then 227392,
228528, 230704, 230768, then flat at 230768 KB for the remaining samples.
RSS rises in steps when the connection level rises (223 MB at 64 connections
to 281 MB at 256), which matches lazily touched pages of the fixed slab.

## Experiment 5: connection scaling

`hello_world` is built with `uz.App(128)`. At 256 and 1024 connections `wrk`
reported 100340 read errors and 2.2k req/s. The `sample` profile of the server
at 1024 connections was dominated by `kevent64` and idle thread-pool waits
(`__ulock_wait2`), with `accept` and `close` calls, which is the capacity limit
closing surplus connections. Use `tls_cluster` with `UWZ_MAX_CLIENTS=2048` for
scaling measurements.

## h2 harness changes made in this session

| Change | Reason |
|--------|--------|
| Missing request counters now fail the sample; the parsed line uses `-` placeholders so fields cannot shift. | An empty field disappeared in word splitting and a non-numeric operand made `[ -eq ]` return 2, which `if` treats as false. |
| Protocol-error pattern is `protocol[ _-]*error`. | The old pattern needed at least one separator and missed `ProtocolError`. |
| Every TLS sample must report `TLS Protocol: TLSv1.3`. | The version was only written to metadata, never verified. |
| Exit status 143 is a failure. | `tls_cluster` installs `catch_shutdown_signals`; status 143 means the handler did not run. `benchmark_http.sh` still accepts 143 because `hello_world` has no handler. |
| Peak, first, last RSS and sample count written to metadata; no samples fails the run. | Peak RSS was not captured and a truncated sampler passed silently. |
| `ulimit -n unlimited`, non-numeric `UWZ_MAX_CLIENTS`, empty `openssl` and `cpu_model` fallbacks, SMT from `/sys/devices/system/cpu/smt/active`. | Silent skips and always-empty fields found in review. |
| `benchmark_http.sh` readiness probe uses `TARGET_URL`. | It was hard-coded to port 3000. |

Verification: the modified script ran two complete matrices against the patched
`tls_cluster` (64 and 256 connections, then nine samples at 64) with exit 0,
TLSv1.3 verified, a clean shutdown with status 0 and no libxev error. For
comparison, before the patch the first sample of the full sweep aborted with
the libxev error and the server needed `SIGKILL`.

## Not done

- The full committed h2 matrix (64 to 2048 connections, 1 and 8 streams, 3
  samples, 10 s). Only reduced matrices ran, in a scratch copy of the env file.
- The plaintext-cluster control.
- Any Linux A/B throughput run. Findings 2 and 3 are kqueue-specific, but
  finding 1 is not: applying only the new scheduler tests to the v2.1.5 tree on
  Linux io_uring fails `scheduler advances at the next timer interval` and
  `does not rearm after a callback stops it`. The zero-request symptom was
  observed on macOS, while the expired-absolute-timeout mechanism is shared by
  every libxev timer implementation.
- A CPU hotspot profile of `tls_cluster` under load.
- Landing the libxev change. Policy requires a `uwz(<area>)` patch commit on
  `farbenbuilds/libxev` branch `uwz/zig-0.16`, review, a full 40-hex pin, and
  all four zon views updated together.
- The `src/core/tcp.zig` `EINVAL` handling for `read error: error.Unexpected`
  (181 warnings in one 30 s run) is unchanged: libxev maps the macOS errno to
  `Unexpected` and the connection is closed, so it is log noise rather than a
  fault.
