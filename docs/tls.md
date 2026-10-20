# TLS

µWebZockets terminates TLS with BoringSSL. There are two ways to give a
server its certificate and key:

| Situation | API | Credentials |
| --- | --- | --- |
| Local development, tests, demos | `init_https_ephemeral` / `init_http3_ephemeral` | Generated in memory at startup |
| Production and shared environments | `init_https` / `init_http3` | PEM files you provide |
| TLS-enabled worker group (TCP) | [`Cluster.enable_https`](#tls-enabled-clusters) / [`Cluster.enable_https_ephemeral`](#tls-enabled-clusters) | PEM files per worker, or generated per worker for development |

Both single-application paths produce the same `TlsContext`, use TLS 1.3 only,
and pick the application protocol through ALPN. The difference is only where
the key material comes from. A worker group applies the same two credential
sources per worker; see [TLS-enabled clusters](#tls-enabled-clusters).

## Development: HTTPS with no certificate files

`App.init_https_ephemeral` generates an ECDSA P-256 key and a self-signed
X.509 certificate with BoringSSL, entirely in memory. There is no `openssl`
command to run, no `.pem` files to manage, and no configuration to keep in
sync with a teammate. A complete HTTPS server is:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn index(_: *uz.Request, response: *uz.Response) void {
    response.text("hello from ephemeral TLS") catch {};
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init_https_ephemeral(init.io);
    defer server.deinit();

    _ = try server.get("/", index);
    try server.listen("0.0.0.0", 3443);
    try server.run();
}
```

```sh
zig build https_server -Doptimize=ReleaseSafe
curl -k https://127.0.0.1:3443/
```

`zig build http3_server` starts the same thing over QUIC on UDP port 8443
using `init_http3_ephemeral`.

### What the generated certificate contains

- ECDSA P-256 key, signed with SHA-256.
- Subject `CN=localhost` and subjectAltName entries for `localhost`,
  `127.0.0.1`, and `::1`.
- `serverAuth` extended key usage, `digitalSignature` key usage, and
  `CA:FALSE` basic constraints, which is what browsers require for a leaf
  certificate.
- Validity from one hour before startup to 90 days after startup. The
  backdating tolerates small clock differences between machines.
- A self-signed issuer identical to the subject.

Pass `tls.CertificateNames` when a project uses a different local hostname:

```zig
const names = uz.tls.CertificateNames{
    .common_name = "api.example.test",
    .dns_names = &.{ "api.example.test", "localhost" },
    .ip_addresses = &.{ "127.0.0.1", "::1" },
};
const credentials = try uz.tls.TlsContext.init_ephemeral(names);
```

The HTTP/3 variant is `TlsContext.init_http3_ephemeral(names)`.

### Why `curl -k` (and what to use instead)

The certificate is self-signed, so no client trusts it automatically. `curl
-k` and the browser "proceed anyway" button skip verification, which is fine
for local smoke tests. When a workflow needs a trusted local certificate
(service workers, HTTP/3 clients with strict verification, mobile devices on
the same LAN), generate one with [`mkcert`](https://github.com/FiloSottile/mkcert)
or your internal CA and pass the files to `init_https`; ephemeral credentials
are deliberately not exportable.

### Lifecycle and allocation

Generation runs once inside `init_*_ephemeral`, before the event loop starts.
BoringSSL allocates while the key and certificate are built, and the library
releases every object it owns (the `SSL_CTX` keeps its own references). After
the call returns, connection setup, handshakes, record processing, and every
request path allocate nothing. Nothing is ever written to disk.

Creating a fresh certificate on every start means restarting invalidates
cached handshakes. That is the right trade-off for development; production
servers should keep long-lived PEM files.

## Production: PEM files

```zig
var server = try uz.App(128).init_https(
    init.io,
    "certs/fullchain.pem",
    "certs/privkey.pem",
);
defer server.deinit();
```

`init_http3` additionally creates the QUIC context and loads the same
certificate and key into both contexts.

- The certificate argument is a PEM chain, leaf first.
- The key argument is a PEM private key. BoringSSL rejects a key that does not
  match the certificate while loading it, so a mismatched pair fails fast with
  `error.PrivateKeyLoadFailed` instead of failing during the first handshake.
- Paths are NUL-terminated Zig slices (`[:0]const u8`).

## TLS-enabled clusters

`Server.builder(...).build_cluster(...)` returns a worker group. Call
`Cluster.enable_https` with production PEM files, or
`Cluster.enable_https_ephemeral` for local development, once after
`configure` and before `listen`:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, response: *uz.Response) void {
    response.text("hello from a TLS worker") catch {};
}

pub fn main(init: std.process.Init) !void {
    var cluster = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .build_cluster(std.heap.page_allocator, 4, .{});
    defer cluster.deinit();

    const Group = @TypeOf(cluster);
    try cluster.configure(struct {
        fn routes(worker: *Group.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    try cluster.enable_https("certs/fullchain.pem", "certs/privkey.pem");
    try cluster.listen("0.0.0.0", 8443);
    try cluster.run();
}
```

The supported order is `build_cluster` -> `configure` -> `enable_https` (or
`enable_https_ephemeral`) -> `listen` -> `run` -> `request_shutdown` or a
shutdown signal -> `deinit`. TLS setup is startup work: `listen` locks routes
and starts accepting, so the enable call must not move after it.

The `4` passed to `build_cluster` is the compiled capacity. Use
`build_cluster_from_environment` to resolve `UWEBZOCKETS_WORKERS` or default to
the platform CPU count; `ClusterOptions.worker_count` selects an explicit
smaller count. Only active workers create TLS contexts, slabs, and threads.

Each worker creates and owns one BoringSSL `SSL_CTX` at enable time, before
any listener exists; every accepted connection creates its own `SSL` from its
worker's context. No credential, session-cache, handshake, or ticket state is
shared between loops, and no lock or allocation is added to the request path.
The certificate and key files are read once per worker at startup, so rotating
credentials requires a rolling restart. Per-worker ticket keys also mean a
reconnect that lands on another worker cannot resume; that boundary is measured
and accepted for the target HTTP workload. Both decisions are recorded in
[ADR 0003](adr/0003-tls-cluster-operational-boundaries.md), and
`Cluster.deinit` releases each context with its worker.

The context keeps the single-application HTTPS policy: TLS 1.3 only, ALPN `h2`
then `http/1.1`, and safe-method 0-RTT with non-safe early data answered `425
Too Early`. `TRACE` joins `GET`, `HEAD`, and `OPTIONS` as a safe early-data
method; `QUERY` remains replay-unsafe. Cluster TLS covers HTTP/1.1 and HTTP/2 over TCP. `enable_https`
does not configure client certificates; use single-application
`init_https_mtls` when mTLS is required.

HTTP/3/QUIC clustering is not supported. `init_http3` and `listen_udp` remain
single-application APIs, and a cluster listener is TCP/TLS only.

| Error | Cause |
| --- | --- |
| `error.ClusterDeinitialized` | An enable call or `listen` was made after `deinit` |
| `error.ClusterRunning` | `enable_https` was called while `run` was active |
| `error.AlreadyListening` | `enable_https` was called after `listen` started |
| `error.TlsAlreadyEnabled` | `enable_https` was called more than once |
| `error.CertificateLoadFailed` | The PEM chain could not be read or parsed |
| `error.PrivateKeyLoadFailed` | The PEM key could not be read or parsed, including a key that does not match the certificate |
| `error.KeyMismatch` | Defensive check only; BoringSSL rejects a mismatched PEM key during key load |
| `error.TlsContextCreationFailed` | BoringSSL could not allocate a context |
| `error.ProtocolConfigurationFailed` | TLS 1.3 bounds could not be applied |
| `error.ApplicationUnavailable` | A worker was already shutting down or deinitialized |

A failed credential load or context creation releases exactly the contexts
that call created and can be retried once the cause is fixed; it never
rewrites or releases a context installed by an earlier successful call. The
lifecycle decision is recorded in
[ADR 0002](adr/0002-tls-cluster-lifecycle.md).

Use `enable_https` with PEM files in production. `enable_https_ephemeral`
generates a distinct self-signed P-256 certificate per worker at startup, takes
no custom names, and is development-only; because each worker presents a
different certificate, it is unsuitable for certificate pinning. It can also
return the `Ephemeral*` generation errors in the
[Zig error reference](#zig-error-reference). TLS cluster support is additive:
the single-application `init_https`, `init_https_ephemeral`, `init_https_mtls`,
`init_http3`, and `init_http3_ephemeral` APIs are unchanged.

```sh
zig build tls_cluster -Doptimize=ReleaseSafe
```

In another terminal:

```sh
curl -sk https://127.0.0.1:8443/
```

The example runs four workers with per-worker ephemeral certificates and
serves `hello from a TLS worker group`.

## Client certificates (mTLS)

Use client-certificate authentication when the caller's identity must be
proven before a request reaches a route: service-to-service APIs, internal
admin surfaces, or device fleets that already hold certificates from a private
CA. The server verifies the client chain against a CA bundle you provide, and
the TLS layer fails the handshake closed before any HTTP parser sees a byte.
Client-certificate modes therefore keep TLS 1.3 early data disabled: the
certificate is only checked in the second flight, after early data has already
reached the server.

```zig
var server = try uz.App(128).init_https_mtls(
    init.io,
    "certs/fullchain.pem",
    "certs/privkey.pem",
    .{ .mode = .required, .ca_path = "certs/client-ca.pem" },
);
defer server.deinit();
```

`tls.TlsContext.init_mtls(cert_path, key_path, config)` is the context-level
entry point and `App.init_https_mtls` is the application-level one. Both keep
the `init`/`init_https` ALPN policy (`h2`, then `http/1.1`). For `.optional`
and `.required`, TLS 1.3 early data is disabled because the client certificate
is not verified until the second flight: the handshake fails closed before any
request is parsed. `.none` keeps the `init`/`init_https` safe-method 0-RTT
policy. `ClientAuthConfig.ca_path` accepts a NUL-terminated (`[:0]const u8`)
path and defaults to empty.

### Modes

`tls.ClientAuth` selects one of three policies:

| Mode | Requests a certificate | Verifies it | Anonymous clients |
| --- | --- | --- | --- |
| `tls.ClientAuth.none` | No | No | Allowed |
| `tls.ClientAuth.optional` | Yes | When presented | Allowed |
| `tls.ClientAuth.required` | Yes | Yes; a missing certificate fails the handshake | Rejected |

`none` is the `init`/`init_https` default and skips the trust store entirely:
no certificate is requested, so BoringSSL never opens `ca_path` and the field
may stay empty. The other modes require a non-empty `ca_path` and reject the
configuration with `error.InvalidClientAuthConfig` otherwise. A bundle that
BoringSSL cannot read or parse fails context creation with
`error.TrustStoreLoadFailed`; a context is never returned with a partially
configured trust store.

### CA bundle format

`ca_path` points at a PEM file of trust anchors for client chains. One file
may hold a single CA certificate or several concatenated in any order;
BoringSSL loads them all. CRLs in the file are loaded into the trust store but
revocation is not enforced, so a revoked certificate still validates until it
expires. Applications that require revocation must check it themselves, for
example against a CRL or an OCSP responder, before trusting the connection.
The bundle is read once when the context is created, so replacing it requires
a restart.

### HTTP/3

Client authentication is TCP-only in 1.7.0. The HTTP/3 context created by
`init_http3` advertises `h3`, keeps early data disabled, and does not request a
client certificate. Wiring client certificates through the QUIC transport is
future work.

## Protocol policy

- TLS 1.3 only; older protocol versions are rejected at the context.
- HTTP/1.1 and HTTP/2 share one context advertising `h2`, then `http/1.1`.
  `ApplicationProtocol` and `select_http_protocol` expose the negotiation
  result.
- HTTP/3 uses a separate context advertising `h3`.
- 0-RTT early data is enabled on the TCP context unless client-certificate
  authentication is configured, in which case it is disabled (see
  [Client certificates](#client-certificates-mtls)). The HTTP dispatcher admits
  only safe methods until the handshake is confirmed, because early data is
  replayable by a network attacker. QUIC keeps early data disabled until
  lsquic's replay policy is wired end to end. Ephemeral contexts inherit both
  policies unchanged.

## C ABI

The equivalent C entry points are declared in
[`include/uWebZockets.h`](../include/uWebZockets.h):

```c
uwz_app *app = NULL;
if (uwz_app_create_tls_ephemeral(&app) != UWZ_OK) {
    /* generation failed */
}
/* register routes, listen, run, destroy as usual */
```

`uwz_app_create_http3_ephemeral` mirrors the Zig HTTP/3 variant. Both generate
the same localhost certificate, so treat them as development tools. When a
generated credential cannot be created, the C layer reports
`UWZ_ERROR_INTERNAL`; the Zig layer returns the specific
`error.Ephemeral*` value.

## Zig error reference

| Error | Meaning |
| --- | --- |
| `CertificateLoadFailed` | The PEM chain could not be read or parsed |
| `PrivateKeyLoadFailed` | The PEM key could not be read or parsed, including a key that does not match the certificate |
| `KeyMismatch` | Defensive context check; a mismatched PEM key already fails during key load |
| `InvalidClientAuthConfig` | A client-auth mode other than `.none` was given with an empty `ca_path` |
| `TrustStoreLoadFailed` | The client CA bundle could not be read or parsed |
| `TlsContextCreationFailed` | BoringSSL could not allocate the context |
| `ProtocolConfigurationFailed` | TLS 1.3 bounds could not be applied |
| `EphemeralKeyGenerationFailed` | P-256 key generation failed |
| `EphemeralCertificateCreationFailed` | X.509 field population failed |
| `EphemeralCertificateExtensionFailed` | SAN or usage extension rejected |
| `EphemeralCertificateSigningFailed` | Self-signature failed |
| `EphemeralCertificateInstallFailed` | The context rejected the credentials |

## Related reading

- [Memory model](memory_model.md) for how TLS connections fit into the
  startup slab.
- [Architecture](architecture.md) for the TCP/QUIC transport and event-loop
  layout behind the handshake.
- [HTTP/2](http2.md) and [HTTP/3](quic.md) for the state machines selected by
  ALPN, and [WebSocket](websocket.md) for RFC 8441 tunnels.
- [Deployment](deployment.md) for the production credential checklist.
