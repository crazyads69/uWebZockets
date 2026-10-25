# H2 over TLS Scaling Guarantee v1

`h2-tls-scaling-v1` is the reproducible measurement contract for
HTTP/2-over-TLS scaling on one host. It characterizes the existing
single-application `init_https` listener, the plaintext worker cluster control,
and the TLS worker cluster delivered in 1.8.5. The machine-readable parameters
live in `h2_tls_scaling_v1.env`; changing any parameter requires a new
benchmark ID and a new history series. `http-throughput-v1` is a separate
contract and is not modified by this one.

## What this contract measures

The contract records requests per second and latency at increasing connection
counts and at one and eight concurrent streams per session. It exists to close
the declared limit that the repository had no 1,024-connection HTTP/2-over-TLS
run and no protocol-equivalent local evidence for the shared-nothing TLS
cluster. It is a characterization and regression baseline, not a competitive
claim: results are only comparable within one host, kernel, toolchain, and
backend cohort.

The current runner supports Linux and macOS. It forces h2load to use `h2`
through TLS ALPN or cleartext prior knowledge, and the server TLS context pins
TLS 1.3. On Linux, the CPU sampler records
cumulative process CPU seconds. On macOS, it records `ps` CPU percent as a
decaying average over up to a minute. Both record RSS in KiB; the TSV column
names keep these observations distinct. Native macOS results are a separate
host/backend cohort and must not be compared with Linux results.

## Cohorts

Every run builds a server at `-Doptimize=ReleaseFast` and runs one of three
configurations. A changed configuration is a new cohort; never combine rows
from different cohorts into one ratio.

1. **Single-app TLS control.** One `init_https` application with one libxev
   loop. This is the model that fell to zero requests per second at 1,024
   connections; it is the failure baseline the cluster must beat.
2. **Plaintext cluster control.** `Server.preset(...).build_cluster(...)` with
   `N` workers over the shared `SO_REUSEPORT` port and no TLS. It isolates the
   TLS cost and the accept-distribution cost.
3. **TLS cluster.** The same cluster with
   `Cluster.enable_https(cert, key)` called once before `listen`, with real PEM
   credentials and TLS 1.3 only. `Cluster.enable_https_ephemeral` and ephemeral
   development credentials must not be used for recorded measurements.

`examples/tls_cluster.zig` accepts `UWZ_MODE` for the three controls
(`tls-cluster`, `plaintext-cluster`, `tls-single`), `UWZ_TLS_CERT` and
`UWZ_TLS_KEY` for real PEM credentials, `UWZ_WORKERS` for 1, 2, 4, or 8
workers, `UWZ_MAX_CLIENTS` for 128, 256, 512, 1024, or 2048 connection slots,
`UWZ_CPU_AFFINITY=0` to leave SMT benchmark workers unpinned, and
`UWZ_TLS_BIND` / `UWZ_TLS_PORT` for the listener. It is a convenience server
for local runs, not a substitute for the adapter under test. The
single-application TLS control always requires PEM files; the cluster modes
reject an `http://` URL and load either the supplied files or per-worker
development certificates.

## Fixed parameters

| Parameter | Value |
| --- | --- |
| Benchmark ID | `h2-tls-scaling-v1` |
| Connections | 64, 256, 512, 1024, 2048 |
| Streams per session | 1 and 8 |
| Duration per sample | 10 s |
| Warmup before sampling | 2 s |
| Samples per cohort | 3 (median reported) |
| Generator | `h2load` from nghttp2 1.69.0 or newer, version recorded per run |
| Protocol | HTTP/2 over TLS 1.3 (`h2` ALPN), keep-alive |
| Request | `GET /` with no body, no query, no extra headers beyond h2load defaults |
| Response | `200` with exact body `hello from a TLS worker group` |
| Server build | `-Doptimize=ReleaseFast` |
| Result schema | 2 (`SCHEMA_VERSION` in the environment file) |

`h2load` is the generator because it is the tool the arena profile uses and it
reports succeeded, failed, errored, and timeout counters separately.

## Success definition

A sample is successful only when all of these hold:

- `failed == 0`, `errored == 0`, and `timeout == 0` in the `h2load` summary;
- every reported status code is `2xx`;
- every `h2load` request counter and the TLS protocol line were parsed; a
  missing counter fails the sample instead of passing silently;
- `h2load` reports `TLS Protocol: TLSv1.3` for every TLS sample;
- a separate `GET /` returns the exact response body above over TLS or
  cleartext HTTP/2 prior knowledge;
- the server logs no panic or protocol error for the sample.

The runner scans the cumulative server log after every sample and again after
clean shutdown for panic, protocol-error (any spelling, including
`ProtocolError`), or libxev `invalid state` text. Other warning lines remain in
the artifact for review.

Any other outcome is reported as a failure and kept in the raw artifacts. A
cohort is not summarized until three successful samples exist and the server
exits with status 0 after `SIGTERM`. A server that dies from the signal's
default action (status 143) did not run its graceful shutdown and fails the
run. If it does not exit within ten seconds, the
runner saves platform-specific process, descriptor, and log diagnostics; on
macOS it also saves a thread sample when `sample` is available. It then sends
`SIGKILL` and polls for up to two more seconds. If the process still appears
alive, the runner records that state and exits without an unbounded wait. The
reported statistics are median requests per second and median p99 latency,
with minimum and maximum spread for both. A process stuck in an uninterruptible
kernel state can outlive the runner until the kernel completes the pending kill.

## Required per-run evidence

Each recorded run stores:

- date and time, hostname, CPU model, core count and quota, kernel, memlock
  limit, selected backend, and backend fallback status when exposed by the
  loop; dynamic Linux builds currently report fallback status as
  `not_exposed`, while macOS kqueue reports `not_applicable_static_backend`;
- the exact uWebZockets commit or tag, Zig version, dependency pins, and
  `flake.lock` hash;
- the server command line, the generator version and flags, the connection and
  stream levels, and the output directory;
- the raw `h2load` output for every sample plus the parsed counters;
- the generator's requests per second, succeeded/failed/errored/timeout
  counters, per-sample minimum/median/p95/p99/maximum latency, and the server
  CPU and RSS observations, including the sample count and the first, peak,
  and last RSS in the metadata file. The first RSS sample can be taken before
  the server has finished starting and is not a baseline;
- the per-cohort median and spread file plus a run-status sentinel that is
  `complete` only after the final shutdown log scan; and
- the observed soft open-file limit, the required descriptor count, the
  listener tool and port, the dirty-tree marker, and the resolved worker value
  and source variable.

Never edit generated benchmark output by hand, and never combine numbers from
different systems into one ratio.

## Reproduction

```sh
# In the checkout under test, inside the pinned Nix shell:
zig build -Doptimize=ReleaseFast

export SSL_CERT_FILE=/path/to/local-ca.pem
export UWZ_MODE=tls-cluster
export UWZ_TLS_CERT=/path/to/fullchain.pem
export UWZ_TLS_KEY=/path/to/privkey.pem
export UWZ_WORKERS=4 UWZ_MAX_CLIENTS=2048 UWZ_CPU_AFFINITY=0
export UWZ_TLS_BIND=127.0.0.1 UWZ_TLS_PORT=8443
scripts/benchmark_h2_tls.sh tls_cluster ./zig-out/bin/tls_cluster \
    /tmp/h2-results https://127.0.0.1:8443/
```

On macOS, use Zig 0.16.0, `h2load` from nghttp2 1.69.0 or newer, `curl`,
`lsof`, and a local CA-signed PEM certificate with `SSL_CERT_FILE` set to that
CA. On Linux, provide `ss` (iproute2) or `lsof` so the runner can verify the
listener owner. The runner records the native backend and available CPU
provenance, but CPU quota and governor are not exposed for a native host; those
fields say so explicitly. Use a new output directory for each host cohort.

The script consumes `h2_tls_scaling_v1.env` directly, so the executable
parameters and the recorded contract cannot drift independently. It refuses to
run without `h2load` 1.69.0 or newer, `curl`, real PEM credentials, or a
listener inspection tool, requires `UWZ_MAX_CLIENTS` to meet or exceed the peak
connection level, and records a failure when any sample reports a non-zero
failure counter. It refuses to start when the target port already has a
listener and verifies after readiness that the launched process owns the
listening socket, so a stale cluster cannot be measured under the new label.
It starts the server itself, samples CPU and RSS, detects the selected backend
from the process descriptors, records per-worker accept counts, and preserves
the raw `h2load` output plus a failure snapshot.
On shutdown timeout, Linux diagnostics include `/proc/PID/status`, socket
states, and the server log tail. macOS diagnostics include process information,
open descriptors, the server log tail, and a one-second `sample` report when
available. The loop currently does not expose a runtime flag proving whether
an epoll selection followed an io_uring initialization failure.
Pass the URL as the fourth argument to use a non-default port or the plaintext
control. The plaintext check uses HTTP/2 prior knowledge because the clear
listener implements no h2c Upgrade. Set `UWZ_CURL_INSECURE=1` only when the
local CA cannot be passed to curl; the recorded metadata notes the choice. The
runner refuses an unknown backend, writes the per-cohort medians to
`<label>_cohort_medians.tsv`, marks `<label>_run.status` complete only after
the final shutdown scan, and keeps platform-specific CPU observations in the
schema-version-2 sampler TSV.

## Committed artifact policy

The runner writes one file per sample for local analysis. Do not commit those
files individually. Each recorded run is committed as one compressed archive
plus `README.md` and `manifest.sha256`, so a results directory stays at three
files. `scripts/check_benchmark_results.sh` runs as part of the convention gate
and rejects any unarchived `.txt`, `.log`, `.tsv`, or `.bin` file under
`benchmarks/results/`. The archive is append-only: extract it, inspect it, and
do not edit the generated output.

## Current status

The contract, runner, and controls ship with the 1.8.9 declared-limits work.
The 1.9.0 characterization ran the full 64-2,048 connection sweep on a shared
development host with real PEM credentials and the io_uring backend. The raw
artifacts, host metadata, and the filled characterization table are in
[`results/h2_tls_scaling_v1/2026_10_19/`](results/h2_tls_scaling_v1/2026_10_19/README.md).
The 4-worker TLS cluster completed all 30 samples with zero failed, errored,
timed-out, or non-2xx requests. At 1,024 connections it reached a median
276,534.80 requests/s at one stream and 669,300.80 at eight streams; the
single-application control served 82,136.60 and 292,140.80 on the same host, so
the historical zero-requests failure did not reproduce here.

This is local characterization evidence, not a quiet-host guarantee and not an
HttpArena result. The host is shared and uses the `powersave` governor, so the
numbers are not comparable to a dedicated runner. The HttpArena `baseline-h2`
restoration still depends on the external adapter repository and an official
arena run; it is re-declared for the maintainer, not claimed by this evidence.
