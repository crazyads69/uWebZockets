# HTTP Throughput Guarantee v1

`http-throughput-v1` is the reproducible performance contract for the
`hello_world` HTTP/1.1 server. The machine-readable parameters live in
`http_throughput_v1.env`; changing any parameter requires a new benchmark ID,
schema, and history series.

## Guarantee

For every pull request targeting `main`, the candidate median requests per
second must be at least 90 percent of the base revision median:

```text
candidate_median_rps >= baseline_median_rps * 0.90
```

Both revisions are built with Zig `ReleaseFast` through their pinned Nix
flakes. They run sequentially on the same GitHub-hosted runner. Each median is
the middle of three `wrk` samples using two threads, 64 connections, a
10-second duration, and `http://127.0.0.1:3000/`.

The guarantee is relative, not an absolute capacity claim. Shared-runner
hardware and scheduling vary over time. Every durable record therefore stores
the runner image, CPU, kernel, tool versions, source revisions, flake-lock
hashes, raw samples, and exact contract checksum. Absolute results should only
be compared within matching runner and toolchain cohorts.

## Durable history

Scheduled and manually dispatched runs on `main` publish immutable records to
the repository's `benchmark-data` branch. That branch contains:

- `records/<year>/<record-id>.json` for canonical structured results;
- `raw/<year>/<record-id>/` for the original `wrk` output and sample rates;
- `index.json` and `latest.json` for automated consumers;
- a generated `README.md` summary; and
- the exact v1 contract and JSON schema describing each record.

The branch is append-only at the record level: publication fails if an existing
record ID has different content. Re-running publication for identical content
is idempotent.

Nightly runs compare `main` with the same `main` revision. These control runs
measure runner variance while producing a long-term mainline throughput series.
Pull-request artifacts retain the same structured record and raw evidence, but
untrusted pull-request jobs never receive history-branch write permission.

## Reproduction

Enter the candidate checkout's Nix environment, build both revisions with
`-Doptimize=ReleaseFast`, and invoke:

```sh
scripts/benchmark_http.sh candidate /path/to/candidate/hello_world /tmp/results
scripts/benchmark_http.sh baseline /path/to/baseline/hello_world /tmp/results
```

The scripts consume `http_throughput_v1.env` directly, so the executable load
parameters and recorded contract cannot drift independently. A sample is
rejected when `wrk` omits or zeroes the requests-per-second value, reports a
socket error or a non-2xx/3xx response, or leaves a malformed counter. The
runner also scans the server log after readiness and shutdown, bounds both
`SIGTERM` and `SIGKILL` shutdown waits, and requires `wrk` plus `python3`.
