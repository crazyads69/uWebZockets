# Troubleshooting

Common symptoms, what they mean, and the smallest fix. If a failure is not
here, open an issue with the exact error name, the command, and the relevant
capacity configuration.

## Capacity and rejection responses

| Status | Meaning | Fix |
| --- | --- | --- |
| `413 Payload Too Large` | Body exceeded `max_body_size` | Raise `with_max_body_size`, or stream the response side with `begin_stream` if the body is output |
| `431 Request Header Fields Too Large` | Request line, header block, or header count exceeded the configured limits | Raise `with_max_request_line_size`, `with_max_header_size`, or `with_max_header_count` |
| `503 Service Unavailable` | A bounded resource is exhausted (for example a second RFC 8441 tunnel on one HTTP/2 connection) | Size the matching capacity; retry on a new connection for the tunnel case |
| `500 Internal Server Error` on route registration | WebSocket limits exceed the configured message capacity, or a helper could not format a response | Lower the route limits or raise the message capacity in `ConfiguredApp` |
| `error.WouldBlock` from WebSocket `send` | The bounded write queue is full | Use the `drain` callback and `buffered_amount` to resume the producer |

Every framework rejection that carries a body uses the structured JSON shape
described in [memory_model.md](memory_model.md), including the limit name and
value.

## Requests fail before the handler

| Status | Cause |
| --- | --- |
| `404 Not Found` | No route matched. Check that you registered the path without the query string; the query is already split into `Request.query` |
| `405 Method Not Allowed` | A route exists for another method; the `Allow` header lists them |
| `425 Too Early` | A non-safe method arrived in TLS 0-RTT early data. The client retries after the handshake |
| `426 Upgrade Required` | A WebSocket route was called without `Upgrade: websocket` |
| `501 Not Implemented` | HTTP/2 or HTTP/3 `CONNECT` outside RFC 8441 extended CONNECT |

## TLS

| Symptom | Cause and fix |
| --- | --- |
| `curl` rejects the certificate | Ephemeral certificates are self-signed. Use `curl -k` for local work, or `mkcert`/your CA plus `init_https` for a trusted certificate |
| `error.PrivateKeyLoadFailed` on a mismatched pair | The PEM certificate and private key do not belong together; BoringSSL rejects the key during load |
| `error.CertificateLoadFailed` / `error.PrivateKeyLoadFailed` | The PEM path is unreadable or malformed; the certificate argument is a chain, leaf first |
| `error.TrustStoreLoadFailed` with mTLS | The client CA bundle is unreadable or malformed |
| `error.InvalidClientAuthConfig` with mTLS | A mode other than `.none` was configured with an empty `ca_path` |
| Handshake fails only for some clients | TLS 1.3 is required; older clients are rejected by design. See [roadmap.md](roadmap.md) |
| HTTP/3 client cannot connect | `listen_udp` must be called, the `App` must stay at a stable address, and the QUIC context advertises only `h3` |

## Client failures

| Failure kind | Meaning |
| --- | --- |
| `.connect` | TCP connect refused, unreachable, or `error.InvalidHostAddress` because `Request.host` is not a numeric IP |
| `.tls` | Verification or handshake failure. `verify = true` requires `ca_path` (BoringSSL ships no default trust store); `error.TlsConfigurationMismatch` means one client was reused with different trust rules |
| `.protocol` | Malformed or conflicting response framing |
| `.timeout` | `connect_timeout_ms` or `read_timeout_ms` expired. Zero expires immediately |
| `.closed` | The peer closed or the socket failed |
| `.capacity` | Response exceeded `response_body_capacity` (at most 64 KiB) or the inflight slot capacity was reached |

See [client.md](client.md) for the full contract.

## Signals and shutdown

- `catch_shutdown_signals` installs one process-wide watcher. A second install
  returns `error.SignalWatcherAlreadyInstalled`; call it once, or use
  `Cluster.catch_shutdown_signals()` for a worker group.
- `error.ApplicationUnavailable` from `run` or `listen` means the application
  was already shut down or deinitialized.
- `deinit` panics if called from inside the event loop. Use `defer` at the same
  scope where the application was created.
- SIGTERM during startup (before the loop runs) is coalesced into one shutdown
  request; nothing is lost.

## Development log

- Nothing prints when stderr is not a terminal. This is intentional so
  redirected runs and benchmarks stay fast. Use `set_dev_log_file` to force
  output, or `with_dev_log(false)` to silence it explicitly.
- HTTP/3 emits request records but does not advance counter metrics yet.
- Failed or short writes are dropped and counted rather than retried; a very
  slow terminal can lose lines by design.

## Cluster

- Workers share the port through `SO_REUSEPORT` on Linux and macOS, and
  `SO_REUSEADDR` on Windows. On Windows the kernel distribution across
  listeners is unspecified; treat it as a graceful fallback, not a
  load-balancing path. Windows is not officially supported because the pinned
  libxev IOCP accept lifecycle blocks the runtime.
- Affinity failures (restricted cpusets, macOS, other platforms) log once and
  leave workers unpinned instead of refusing startup.
- `Cluster.enable_https` is startup-only: call it once after `configure` and
  before `listen`. `error.TlsAlreadyEnabled` means a context is already
  installed, `error.AlreadyListening` means `listen` ran first,
  `error.ClusterRunning` means `run` is active, and
  `error.ClusterDeinitialized` means the cluster was already released. Remove
  the duplicate call, fix the order, or rebuild the cluster.
- `error.CertificateLoadFailed` and `error.PrivateKeyLoadFailed` at enable time
  map to the same PEM problems as the single-application TLS path: an
  unreadable or malformed chain/key, or a pair that does not belong together
  (BoringSSL rejects a mismatched key during load). A failed enable releases
  only the contexts it created, so correct the files and retry;
  `enable_https_ephemeral` avoids files for local work.
- HTTP/3/QUIC clustering is not supported. `init_http3` and `listen_udp` remain
  single-application APIs.
- `Cluster.request_shutdown` requests shutdown for every worker;
  `App.request_shutdown` is the cross-thread-safe single-app entry, while
  `App.shutdown` must run on the owning loop thread. The cluster method
  returns `void` and cannot report a lifecycle error, so calling it after
  `deinit` is a documented no-op on the released worker slice; check your own
  generation counter or rebuild the cluster instead of awaiting an error.
- On Linux the loop uses io_uring when the kernel allows it and falls back to
  epoll when a container seccomp policy or old kernel rejects the ring, so
  Docker Desktop and OrbStack hosts no longer need `--privileged` just to
  start. The fallback moves blocking file operations to a small thread pool;
  throughput-sensitive deployments should still prefer io_uring.

## HTTP/3

- Extended CONNECT, WebTransport, push, and application datagrams are rejected
  by the live listener by design; see [quic.md](quic.md) and
  [ADR 0001](adr/0001-http3-datagram-and-webtransport.md).
- The cross-implementation gate is the reference for supported behavior; a
  client that needs a rejected feature will receive a protocol error, not a
  silently ignored request.

## Getting help

- Bugs and feature requests: the repository issue tracker, with the exact error
  name, platform, and configuration.
- Security reports: follow [SECURITY.md](../SECURITY.md) and do not open a
  public issue.
- Contribution workflow: [CONTRIBUTE.md](../CONTRIBUTE.md).
