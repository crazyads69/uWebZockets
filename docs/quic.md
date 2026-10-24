# QUIC and HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises `h2` and
`http/1.1`, while QUIC advertises only `h3`. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`. The `App` value must remain at a
stable address after `listen_udp`.

```zig
var server = try uz.App(128).init_http3(init.io, "certs/fullchain.pem", "certs/privkey.pem");
defer server.deinit();

_ = try server.get("/", hello);
try server.listen("0.0.0.0", 3443);      // TCP/TLS
try server.listen_udp("0.0.0.0", 8443);  // QUIC
try server.run();
```

For local development, `init_http3_ephemeral` generates an in-memory
certificate; see [tls.md](tls.md).

## Request path

The adapter decodes HTTP/3 pseudo-headers directly into the existing `Request`
shape and writes structured QPACK response headers without converting through
HTTP/1.1 text. QUIC connections, streams, header sets, packet buffers, and
bodies come from startup-allocated contiguous pools.

- The live listener explicitly rejects TLS 0-RTT so replayable application
  requests never reach a handler. Pure early-data policy helpers remain
  available for a future backend that exposes per-request early-data state.
- Congestion control is pinned to BBRv1 with per-connection pacing.
- Linux transmit batching coalesces equal-sized packets for one destination into
  one `sendmsg` with `UDP_SEGMENT` (GSO). Mixed sizes and other platforms use the
  per-packet path. Receive-side `UDP_GRO` is disabled because the event loop does
  not expose ancillary segment boundaries; a coalesced buffer would be misread as
  one QUIC datagram.
- The engine enforces decoded header limits, request bodies, packet buffers,
  connections, and active streams through `ServerConfig`.
- Request validation is strict: pseudo-fields must precede regular fields and
  stay unique, `:protocol` is accepted only on CONNECT requests that carry
  `:authority`, and connection-specific fields are rejected as malformed with
  a stream-scoped `H3_MESSAGE_ERROR`.

## Observability

HTTP/3 emits one `http_request` development-log record per completed
request/response cycle through the owning thread's sink. The QUIC path does not
advance the counter registry in this release.

## RFC 10008 `QUERY`

Both routing APIs support the `QUERY` method. It rejects a missing or
syntactically invalid `Content-Type`; resource-specific media-type and content
consistency remain the handler's policy.

`TRACE` is also first-class and opt-in: `:method: TRACE` reaches a registered
handler, but the library never synthesizes an echo route. `method_is_replay_safe`
classifies TRACE as safe for early-data forwarding policy.

## Extended CONNECT, WebTransport, and datagrams

`uz.http3_extensions` supplies RFC 9220 extended CONNECT validation, push
bookkeeping, and replay-aware early-data policy. `uz.webtransport` supplies
bounded draft-16 settings, CONNECT/origin checks, sessions, stream and datagram
association, capsules, flow control, and error mapping.

Those extension modules are **not connected to the live lsquic listener**. The
maintained fork backend currently exposes raw datagrams but not the complete
extended CONNECT, outgoing unidirectional stream, or reset-at interfaces they
require, and the build does not yet enable the WebTransport server compile
option. The live
listener rejects CONNECT with `501 Not Implemented`, and WebTransport models
draft-16 only: it is not a claim of deployed interoperability.

[adr/0001-http3-datagram-and-webtransport.md](adr/0001-http3-datagram-and-webtransport.md)
records the exact backend blockers and the accepted implementation plan. The
maintained `farbenbuilds/lsquic` fork can carry the missing server interfaces,
but the live path remains capability-gated until the 2.2.0 implementation and
compliance gate land.

## Verification

The cross-implementation gate uses pinned curl/ngtcp2 and aioquic clients to
verify the normal request path, a valid trailing field section, and malformed
pseudo-header/connection-field rejection with `H3_MESSAGE_ERROR`. Malformed and
healthy sibling streams share one connection so connection-wide aborts fail the
gate. The gate then soaks more malformed requests than the engine's full header
pool (`2 * connection capacity`), requires a healthy request on a fresh
connection, and requires the server to exit cleanly so `deinit` can assert that
every pool was drained. The gate retains server logs, traces, versions, results,
and qlogs; see [operations.md](operations.md) and
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md).
