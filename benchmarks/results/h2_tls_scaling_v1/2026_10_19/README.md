# h2-tls-scaling-v1 local evidence, 2026-10-19

This directory is the raw artifact set for the 1.9.0 characterization of the
existing plaintext and TLS worker clusters. It is local evidence from one
shared development host, not a quiet-host competitive claim and not an
HttpArena run. The contract parameters in
[`../../../h2_tls_scaling_v1.env`](../../../h2_tls_scaling_v1.env) were not changed;
the env file only gained quotes so a POSIX shell can source its lists.

## Host and toolchain

| Field | Value |
| --- | --- |
| Hostname | chimera-btw |
| CPU | AMD Ryzen AI 7 350 w/ Radeon 860M |
| Topology | 8 physical cores, 16 logical CPUs, SMT active |
| Governor | powersave |
| Kernel | 7.2.2-0-generic |
| Memlock | 8192 KiB |
| Open files | 4096 |
| Zig | 0.16.0 |
| h2load | nghttp2 1.69.0 |
| OpenSSL | 3.6.4 |
| libxev backend | io_uring |
| TLS | TLS 1.3, ALPN h2, local CA-signed leaf |
| Certificate SHA-256 | `3D:C2:66:5E:04:73:BA:00:4E:09:15:87:E1:45:DF:03:1B:87:43:17:4A:05:00:05:C9:AE:C0:89:D9:D8:0C:31` |
| Build | `-Doptimize=ReleaseFast`, `UWZ_CPU_AFFINITY=0` |
| Server | `examples/tls_cluster.zig` |

The server ran with `UWZ_MAX_CLIENTS=2048`, above the 2,048-connection peak, so
no row closed for capacity. Credentials were real PEM files signed by a local
CA, not `enable_https_ephemeral`; the CA and key lived under `/dev/shm` and were
never committed. The measured binary was the release/v1.9.0 working tree before
the final documentation commit; the post-commit 256/1024 row is recorded
separately below.

## Full contract: 4-worker TLS cluster

Every one of the 30 samples reported `0 failed`, `0 errored`, `0 timeout`, and
`0 non-2xx`. Three samples per cohort; rate is the median.

| Connections | Streams | Median req/s | Median request | Median p99 |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 1 | 392,492.60 | 125 us | 293 us |
| 64 | 8 | 753,800.00 | 455 us | 1.13 ms |
| 256 | 1 | 391,752.60 | 518 us | 1.09 ms |
| 256 | 8 | 744,708.80 | 1.85 ms | 4.51 ms |
| 512 | 1 | 343,462.70 | 1.26 ms | 2.44 ms |
| 512 | 8 | 704,476.80 | 4.02 ms | 9.38 ms |
| 1,024 | 1 | 276,534.80 | 3.20 ms | 5.60 ms |
| 1,024 | 8 | 669,300.80 | 8.80 ms | 19.00 ms |
| 2,048 | 1 | 223,515.90 | 8.71 ms | 11.55 ms |
| 2,048 | 8 | 656,539.20 | 17.41 ms | 38.22 ms |

Per-worker accepts from the run: 5,789 / 5,827 / 6,047 / 5,763 (worker 0 to
3), 23,426 total, all closed. The spread is 4.8 percent around the mean, so the
accept path was not single-worker-bound.

## Protocol-equivalent plaintext control

The same 4-worker cluster and the same contract levels without TLS completed
all 30 samples with zero failures. Median requests per second:

| Connections | Streams | Plaintext req/s | TLS req/s | TLS share |
| ---: | ---: | ---: | ---: | ---: |
| 256 | 1 | 761,023.30 | 391,752.60 | 51.5% |
| 256 | 8 | 885,283.80 | 744,708.80 | 84.1% |
| 1,024 | 1 | 560,300.30 | 276,534.80 | 49.4% |
| 1,024 | 8 | 842,541.20 | 669,300.80 | 79.4% |
| 2,048 | 1 | 418,362.50 | 223,515.90 | 53.4% |
| 2,048 | 8 | 830,538.90 | 656,539.20 | 79.1% |

Per-worker accepts were 5,733 / 5,939 / 5,899 / 5,855, also balanced.

## Single-application TLS control

The historical failure was zero requests per second at 1,024 connections on
the single-loop `init_https` listener. It did **not** reproduce on this host:
the control served every sample. This is recorded rather than hidden, and it
means the cluster result is a scaling comparison, not a rescue of a failing
control on this machine.

| Connections | Streams | Median req/s | Median p50 | Median p99 |
| ---: | ---: | ---: | ---: | ---: |
| 256 | 1 | 159,921.50 | 1.54 ms | 2.11 ms |
| 256 | 8 | 326,884.00 | 5.70 ms | 9.18 ms |
| 1,024 | 1 | 82,136.60 | 12.23 ms | 14.73 ms |
| 1,024 | 8 | 292,140.80 | 24.94 ms | 30.09 ms |

At 1,024 connections, four workers delivered 3.37 times the single-loop
throughput at one stream and 2.29 times at eight streams.

## Worker scaling at 1,024 connections

TLS cluster, three samples per point, same host and flags.

| Workers | Streams | Median req/s | Median p99 |
| ---: | ---: | ---: | ---: |
| 1 | 1 | 83,097.40 | 14.18 ms |
| 2 | 1 | 155,468.10 | 8.18 ms |
| 4 | 1 | 276,534.80 | 5.60 ms |
| 1 | 8 | 290,559.20 | 31.74 ms |
| 2 | 8 | 502,156.80 | 21.57 ms |
| 4 | 8 | 669,300.80 | 19.00 ms |

The 2-worker accept split was 2,983 / 3,162 (48.5 / 51.5 percent). Throughput
scaled with worker count and p99 fell, which is the expected single-loop
saturation signature rather than a flow-control or accept-path defect.

## Characterization table

| Hypothesis | Probe | Evidence | Result |
| --- | --- | --- | --- |
| Single-loop saturation | 1 / 2 / 4 workers at 1,024 connections | 83k / 155k / 277k req/s at one stream, 291k / 502k / 669k at eight streams | Confirmed; throughput scales and p99 falls with workers |
| Accept-path imbalance | Per-worker `connections_accepted` | 4-worker TLS spread 4.8 percent; 2-worker split 48.5 / 51.5 percent | No imbalance observed |
| Handshake cost dominates | `connect` and `TTFB` rows in the raw h2load output; plaintext control | 64-connection TLS connect median 2.35-8.43 ms in the validation sample; TLS throughput is 49-84 percent of plaintext depending on streams | Handshake cost is visible but does not collapse scaling; no connection storm was optimized |
| Stream or flow-control stall | Raw `timeout`, `failed`, `errored`, p99, and full contract rows | Zero failures/timeouts in 30 TLS and 30 plaintext samples; p99 rises smoothly with load | No window or write-queue stall observed; no window change made |
| Slab capacity | `UWZ_MAX_CLIENTS=2048` above the 2,048 peak | Zero capacity errors or closes; all worker accepted counts equal closed counts | Capacity was sufficient |
| Per-worker session tickets | `scripts/probe_tls_resumption.sh` | 1 worker: 20 new / 100 reused; 4 workers: 97 new / 23 reused; 0 failures | Cross-worker resumption is bounded by per-worker ticket keys; accepted in ADR 0003 |
| Profiling availability | `perf_event_paranoid` and h2load connect rows | Kernel profiling is restricted on this host; user-space connect/TTFB and CPU/RSS samples are archived | No kernel profile claimed |

## Post-commit verification

After the release commit, the 256- and 1,024-connection TLS rows at one and
eight streams were rerun three times each from the committed tree. The archive
contains `post_commit/post_commit_summary.tsv` with the exact rates and
latencies. This gives the contract rows an exact commit identifier even though
the full 64-2,048 sweep was collected from the immediately preceding working
tree.

## Artifact archive

| Path | Contents |
| --- | --- |
| `README.md` | Host record, result tables, hypothesis decisions, and reproduction commands |
| `raw_evidence_archive.tgz` | Append-only archive of all raw h2load outputs, parsed summaries, metadata, CPU/RSS samples, worker accepts, server logs, exact body bytes, resumption evidence, post-commit rows, and the clean-clone build log |
| `manifest.sha256` | SHA-256 of this README and the raw evidence archive |

Extract the raw evidence with:

```sh
mkdir -p /tmp/uwz-h2-evidence
tar -xzf raw_evidence_archive.tgz -C /tmp/uwz-h2-evidence
```

Inside the archive, each `*_raw.txt` file contains the three sample outputs for
one cohort, separated by `===== sample N =====` headers. The derived
`*_rates.txt` intermediates are not included because `summary.tsv` carries
every rate and counter. Raw output was not rewritten; samples were only
concatenated with headers before archiving. The convention gate rejects any
unarchived raw file under `benchmarks/results/`, so the next recorded run keeps
this same three-file shape.

Teardown logs contain `error.BrokenPipe` and `error.ConnectionResetByPeer`
warnings while h2load closes its clients; every sample still reported zero
failed, errored, timed-out, or non-2xx requests. No panic, assertion, or
protocol error appears in any server log.

## Reproduction

```sh
zig build -Doptimize=ReleaseFast

export PATH=/path/to/nghttp2/bin:$PATH
export SSL_CERT_FILE=/path/to/local-ca.pem
export UWZ_MODE=tls-cluster
export UWZ_TLS_CERT=/path/to/server.pem
export UWZ_TLS_KEY=/path/to/server.key
export UWZ_WORKERS=4 UWZ_MAX_CLIENTS=2048 UWZ_CPU_AFFINITY=0
export UWZ_TLS_BIND=127.0.0.1 UWZ_TLS_PORT=9443
scripts/benchmark_h2_tls.sh tls_cluster_w4 ./zig-out/bin/tls_cluster \
    /tmp/h2-results https://127.0.0.1:9443/
```

Use `UWZ_MODE=plaintext-cluster` with an `http://` URL for the control, or
`UWZ_MODE=tls-single UWZ_WORKERS=1` for the single-application listener.
`scripts/probe_tls_resumption.sh 127.0.0.1:9443 20` records the ticket mix.
