# 0001. HTTP/3 datagrams and WebTransport activation

- Status: Accepted: deferred
- Date: 2026-09-26
- Deciders: QUIC/HTTP3 engineering
- Pinned dependency: litespeedtech/lsquic commit
  `a9616720af78b9aab895145c1792d5305c480ae8` (LSQUIC_MAJOR_VERSION 4,
  LSQUIC_MINOR_VERSION 10, LSQUIC_PATCH_VERSION 2), Zig package hash
  `N-V-__8AAH6VZwAKiOkYrd_YSpAX_LDuhK6AYwKdPAW-Yg-d`.

## Context

µWebZockets ships Zig-only HTTP/3 extension surfaces: RFC 9220/RFC 8441
extended CONNECT validation and push bookkeeping
(`src/quic/http3_extensions.zig`), WebTransport draft-16 settings, sessions,
stream/datagram association, capsules, and flow control
(`src/quic/webtransport.zig` and its `webtransport/` submodules), a bounded
datagram ring (`src/quic/datagram_ring.zig`), and datagram routing
(`src/router/datagram.zig`). None of them is connected to the live listener.

The live listener is `quic_engine` in `src/quic/engine.zig` over the pinned
lsquic build, and it serves bounded RFC 9114 request/response routing
(`src/quic/stream.zig`). A live `CONNECT` request receives `501 Not
Implemented` in `src/quic/stream.zig`, so no extended CONNECT session can
exist and `App.datagram*` (`src/router/app.zig`) is currently unreachable from
QUIC input.

The question this ADR answers: can RFC 9297 HTTP/3 datagrams be wired to the
existing public `App.datagram*` surface and slab rings with no new public API
and with behavior testable by the existing harness? The answer is no, for the
reasons below. This record is the precise blocker note required by the
implementation task.

### What the pinned lsquic exposes

Present in the pinned public surface (`include/lsquic.h` in the lsquic package
tree):

- Raw QUIC DATAGRAM callbacks in `struct lsquic_stream_if`:
  `on_dg_write` (line 197) and `on_datagram` (line 202).
- The `es_datagrams` engine setting (line 1068); the upstream default is off
  (`LSQUIC_DF_DATAGRAMS 0`, line 447).
- `lsquic_conn_want_datagram_write` (line 2004) and
  `lsquic_conn_set_min_datagram_size` (line 2013).
- With `es_datagrams`, lsquic encodes the RFC 9221 `max_datagram_frame_size`
  transport parameter (`src/liblsquic/lsquic_enc_sess_ietf.c`, `gen_trans_params`
  and `lsquic_enc_sess_ietf_gen_quic_ctx`, plus the peer-parameter enable in
  `src/liblsquic/lsquic_full_conn_ietf.c`, all gated on `settings->es_datagrams`).

The current engine policy in `src/quic/engine.zig` leaves `es_datagrams` at
its zero default, so the live listener advertises nothing datagram-related
today. The capability record `extensions.lsquic_4_10_0_capabilities` in
`src/quic/http3_extensions.zig` marks `quic_datagrams = true` in the sense
that the backend primitive exists; it does not claim the listener enables it.

### What the pinned lsquic does not expose

The project compiles lsquic from source with a fixed define list in
`builds/vendor/lsquic.zig` (`definitions`), and it does not define
`LSQUIC_WEBTRANSPORT_SERVER_SUPPORT`. Upstream gates that macro behind
`OPTION(LSQUIC_WEBTRANSPORT "Enable WebTransport support" OFF)` and
`-DLSQUIC_WEBTRANSPORT_SERVER_SUPPORT=1` in `CMakeLists.txt`. With the macro
undefined, every server WebTransport block compiles out:

- Extended CONNECT: `SETTINGS_ENABLE_CONNECT_PROTOCOL` (0x08) is emitted only
  inside the macro block in `src/liblsquic/lsquic_hcso_writer.c`; there is no
  other path to advertise it.
- HTTP/3 datagrams: `SETTINGS_H3_DATAGRAM_ENABLED` (0x33) is emitted only in
  the same macro block, so the pinned build never advertises RFC 9297 H3
  datagrams even if the RFC 9221 transport knob were enabled.
- WebTransport session API: `es_webtransport_server`,
  `es_max_webtransport_server_streams`, `lsquic_stream_set_webtransport_session`,
  `lsquic_stream_is_webtransport_session`,
  `lsquic_stream_is_webtransport_client_bidi_stream`, and
  `lsquic_stream_get_webtransport_session_stream_id` exist in
  `include/lsquic.h` only under the macro. The settings the macro emits are
  the earlier draft identifiers 0x2b603742 and 0x2b603743, not the draft-16
  `SETTINGS_WT_ENABLED` 0x2c7cf000 that `src/quic/webtransport.zig` models.
- Server-initiated unidirectional streams: the only stream-creation entry
  point is `lsquic_conn_make_stream` (line 1628), which creates a request
  (client-initiated bidirectional) stream. There is no server-initiated
  unidirectional stream API.
- `RESET_STREAM_AT`: no `reset_stream_at` symbol exists anywhere in the pinned
  header or `src/liblsquic`; the helper constants
  (`reset_stream_at_parameter` 0x1d, `reset_stream_at_frame` 0x24 in
  `src/quic/webtransport/settings.zig`) have no backend implementation.
- Server push: there is no public PUSH_PROMISE/MAX_PUSH_ID API. The only
  related surface is the `is_push_promise` argument of the
  `hsi_create_header_set` callback (`include/lsquic.h` line 1375), and
  `src/quic/engine.zig` rejects it by returning null.

### Why raw datagrams still cannot reach `App.datagram*`

Even setting the missing macro aside, mapping `on_datagram` to the existing
application surface is not contained:

- `App.dispatch_datagram(connection_index, session_id, sequence_number, path,
  payload)` (`src/router/app.zig`) needs a connection index into
  `datagram_rings` and a session path. `on_datagram` receives an
  `lsquic_conn_t` and raw bytes; the engine keeps only an anonymous
  `active_connections` count and never sees the `App` or its datagram tables.
  `quic_transport` (`src/core/udp.zig`) borrows only the TLS context and
  `Router`.
- An RFC 9297 payload is a quarter-stream ID varint followed by the
  WebTransport payload (`src/quic/webtransport/datagrams.zig`). Resolving the
  session, path, and monotonic sequence number requires the extended CONNECT
  session state that the live listener rejects with 501, plus per-session
  sequence bookkeeping that lsquic does not provide.
- The HTTP/3 compliance gate drives pinned curl/ngtcp2 and aioquic clients
  (`scripts/http3_compliance/`); neither exercises WebTransport sessions or
  datagrams, so an unverified runtime path would ship without a gate.

## Decision

Defer. Do not wire HTTP/3 datagrams or WebTransport into the live listener and
do not add public API for them. Keep `BackendCapabilities` truthful: raw
datagram primitives exist, every WebTransport-required primitive does not.
The helper modules remain Zig-only, validated by unit and fuzz tests, and are
not a claim of deployed interoperability.

## Consequences

- The live wire behavior stays bounded RFC 9114 request/response plus the
  existing gates; no public surface changes.
- `docs/protocols.md` points here for the datagram/WebTransport status and
  `SECURITY.md` keeps its statement that extended CONNECT and application
  datagrams are not live.
- Activation is capability-gated. If upstream exposes extended CONNECT,
  server-initiated unidirectional streams, `RESET_STREAM_AT`, push, and the
  draft-16 settings, the work would be: flip the matching
  `BackendCapabilities` bits only after the engine verifies and advertises the
  settings; bind the existing `webtransport.session_slab`,
  `datagram_ring.DatagramRing`, and `router/datagram.zig` tables to engine
  connection slots; route decoded quarter-stream-ID datagrams through
  `App.dispatch_datagram`; and extend the HTTP/3 compliance gate with a
  WebTransport client before claiming interoperability.
- Any future lsquic bump must re-check the `LSQUIC_WEBTRANSPORT` gate and the
  `builds/vendor/lsquic.zig` define list before any capability bit changes.

## References

- Pinned lsquic `include/lsquic.h`: stream callbacks, `es_datagrams`,
  `lsquic_conn_make_stream`, WebTransport `#if` blocks.
- Pinned lsquic `src/liblsquic/lsquic_hcso_writer.c`: settings emission gate.
- Pinned lsquic `src/liblsquic/lsquic_enc_sess_ietf.c`,
  `src/liblsquic/lsquic_full_conn_ietf.c`: transport datagram parameters.
- Pinned lsquic `CMakeLists.txt`: `LSQUIC_WEBTRANSPORT` option.
- Project: `builds/vendor/lsquic.zig`, `src/quic/engine.zig`,
  `src/quic/stream.zig`, `src/quic/http3_extensions.zig`,
  `src/quic/webtransport.zig`, `src/quic/webtransport/datagrams.zig`,
  `src/quic/datagram_ring.zig`, `src/router/datagram.zig`,
  `src/router/app.zig`, `src/core/udp.zig`.
- RFC 9114 (HTTP/3), RFC 9220 (extended CONNECT), RFC 8441 (WebSocket over
  HTTP/2/3), RFC 9221 (QUIC DATAGRAM), RFC 9297 (HTTP/3 datagrams),
  draft-ietf-webtrans-http3-16 (WebTransport over HTTP/3).
