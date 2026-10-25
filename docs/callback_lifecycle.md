# Callback life cycle

This page is the registration-to-handler map for every asynchronous entry
point in the native runtime. It complements [architecture.md](architecture.md)
(data flow and shutdown ordering), [memory_model.md](memory_model.md) (storage
ownership), and [protocols.md](protocols.md) (wire behavior) without repeating
them.

References are `file:line` against the current tree and move with the code.
Native libxev completion callbacks return `xev.CallbackAction`; callbacks
registered with C interfaces or invoked by a handler keep their own
signatures, noted at each entry point. The completion a libxev callback
receives is an inline field of the owning connection, server, timer, or
transport. `.rearm` keeps an operation registered; `.disarm` leaves re-arming
or cancellation to the handler. Every cancellation routes through
`core_loop.cancel` (`src/core/loop.zig:24`), which synthesizes the completion
on kqueue and IOCP instead of calling the backend directly.

## TCP accept path

- `AcceptCallback` (`src/core/tcp.zig:1460`) is the listener connection
  callback type. `init_server` (`src/core/tcp.zig:1475`) and
  `init_reuse_port_server` (`src/core/tcp.zig:1480`) store the callback passed
  by `App.listen` (`src/router/app.zig:888`) and `App.listen_reuse_port`
  (`src/router/app.zig:1117`) as `on_new_connection`
  (`src/router/app.zig:790`).
- `on_accept_complete` (`src/core/tcp.zig:1644`) is registered by
  `accept_start` (`src/core/tcp.zig:1593`) at `src/core/tcp.zig:1595`.
  Signature: `xev.AcceptError!xev.TCP` result plus `xev.CallbackAction`.
  Driven by a completed accept. It calls `server.on_connection`
  (`src/core/tcp.zig:1666`) and returns `.rearm`.
- `on_new_connection` (`src/router/app.zig:790`) acquires a pool slot
  (`src/router/app.zig:796`), resets protocol state
  (`src/router/app.zig:804`), attaches TLS (`src/router/app.zig:875`), and
  arms the first read (`src/router/app.zig:880`). Driven by the accept
  callback above.
- `on_accept_cancel_complete` (`src/core/tcp.zig:1632`) is registered by
  `close_server` (`src/core/tcp.zig:1605`) through `core_loop.cancel`
  (`src/core/tcp.zig:1609`). Driven by shutdown cancellation of accept.
- `on_server_close_complete` (`src/core/tcp.zig:1670`) is registered at
  `src/core/tcp.zig:1623` by `close_server`. It sets the flag
  `App.verify_shutdown` (`src/router/app.zig:425`) waits on. Driven by the
  listener close completion.

## TCP read, TLS, and dispatch

- `on_read_complete` (`src/core/tcp.zig:1144`) is registered by `arm_read`
  (`src/core/tcp.zig:838`) at `src/core/tcp.zig:841`. Signature:
  `xev.ReadError!usize` plus the read buffer. Driven by a readable socket; it
  returns `.rearm` (`src/core/tcp.zig:1196`) unless dispatch is suspended or
  the connection is closing.
- `read_start` (`src/core/tcp.zig:1139`) is the bootstrap called after pool
  acquire; it stores the loop and calls `arm_read`.
- `on_read_complete` calls `process_tls_data` (`src/core/tcp.zig:1185`) when
  TLS is attached, otherwise `route_decrypted_data`
  (`src/core/tcp.zig:1187`).
- `process_tls_data` (`src/core/tcp.zig:201`) drives the handshake
  `drive_tls_handshake` (`src/core/tcp.zig:230`) and then
  `drain_tls_plaintext` (`src/core/tcp.zig:260`); the drain loop feeds
  `route_decrypted_data` at `src/core/tcp.zig:267`.
- `route_decrypted_data` (`src/core/tcp.zig:286`) selects HTTP/1
  `route_http_data` (`src/core/tcp.zig:585`), HTTP/2 `route_http2_data`
  (`src/core/tcp.zig:320`), or `WebSocket.on_data` (`src/ws/socket.zig:246`).
- HTTP/2 runs synchronously inside the read callback: `route_http2_data`
  calls `h2.receive` (`src/core/tcp.zig:322`), whose entries come from
  `http2_callbacks` (`src/core/tcp.zig:329`): `write_http2_parts`
  (`src/core/tcp.zig:352`), `dispatch_http2_request`
  (`src/core/tcp.zig:372`), `ws_http2_data` (`src/core/tcp.zig:357`), and
  `close_http2_stream` (`src/core/tcp.zig:343`).
- `resume_async_dispatch` (`src/core/tcp.zig:796`) re-enters `route_http_data`
  and can call `drain_tls_plaintext` (`src/core/tcp.zig:828`) before re-arming
  the read.

## TCP write path and file body

- `on_write_complete` (`src/core/tcp.zig:1199`) is registered by `start_write`
  (`src/core/tcp.zig:1015`) at `src/core/tcp.zig:1021`. Signature:
  `xev.WriteError!usize`. Driven by a writable socket.
- The handler advances the write ring and then calls `flush_tls_out`
  (`src/core/tcp.zig:1246`), `drive_tls_handshake`
  (`src/core/tcp.zig:1252`), `h2.flush_pending` (`src/core/tcp.zig:1259`),
  `WebSocket.notify_drain` (`src/core/tcp.zig:1267`),
  `tcp_file.pump_file_body` (`src/core/tcp.zig:1275`), and `start_write`
  (`src/core/tcp.zig:1276`).
- `pump_file_body` (`src/core/tcp_file.zig:54`) streams the response file at
  the kernel boundary; `dribble_file_body` (`src/core/tcp_file.zig:107`) is
  the bounded copy fallback and `finish_file_body`
  (`src/core/tcp_file.zig:32`) releases the handle and resumes dispatch.
  There is no file-body timer: each write completion is the pulse.

## TCP close and pool release

- `close_connection` (`src/core/tcp.zig`) is idempotent teardown. It
  aborts the connection signal (`src/core/tcp.zig:1311`), cancels async
  tokens (`src/core/tcp.zig:1317`), releases file and TLS state
  (`src/core/tcp.zig:1321`, `src/core/tcp.zig:1322`), cancels read and write
  through `core_loop.cancel` (`src/core/tcp.zig:1332`,
  `src/core/tcp.zig:1343`), and submits `socket.close`
  (`src/core/tcp.zig:1365`) with the inline close callback
  (`src/core/tcp.zig:1370`). Windows closes synchronously and releases
  immediately (`src/core/tcp.zig:1355`).
- `on_read_cancel_complete` (`src/core/tcp.zig:1403`) and
  `on_write_cancel_complete` (`src/core/tcp.zig:1418`) clear their cancel
  flags and re-run the release gate. Driven by the cancellation completions.
- `release_closed_connection` (`src/core/tcp.zig`) is the only path back
  to the freelist. Once close, read, write, and cancel flags are clear it
  invokes `on_close_cb` (`src/core/tcp.zig:1456`), the pool release closure
  installed at `src/router/app.zig:867`.
- `close_after_flush` (`src/core/tcp.zig:1293`) is the graceful variant: it
  starts the TLS shutdown and closes only when queued bytes drain.

## Timers

- `timer_wheel.Wheel` (`src/core/timer_wheel.zig`) owns intrusive `TimerNode`
  entries. Nodes live inside the connection slab (`TcpConnection.idle_timer`
  and `TcpConnection.sleep_slots`), so scheduling, cancellation, and expiry
  never allocate. Four levels cover 0 to 18.64 hours; longer deadlines wait in
  an overflow list and enter the wheel when they are within range.
- `timer.Scheduler` (`src/core/timer.zig`) owns one persistent libxev timer
  per worker loop. It wakes on a bounded five-millisecond tick while deadlines
  exist, advances the wheel, and cascades nodes. The completion is never reset
  or reused. `stop` does not cancel; the bounded tick wakes once more and
  disarms after observing the stop flag. This avoids IOCP's queued-callback
  race at the cost of a 5 ms tick when timers exist.
- `TcpConnection.touch_activity` arms the keep-alive deadline, or the
  incomplete-header deadline while a request head or body is partial. A
  connection with parked delayed responses suppresses the idle deadline.
  `on_idle_timeout` closes through `tcp.close_connection`; `cancel_timers`
  removes every connection-owned node before the slot returns to the pool.
- `AsyncResponse.sleep` and `AsyncResponse.sleep_complete` park an HTTP/1
  request in slot 0 or an HTTP/2 stream in its per-stream slot. Expiry invokes
  the application resume callback or completes the stored response, then
  re-arms the idle deadline. `close_http2_stream` cancels the stream's slot so
  a reset peer cannot run a stale callback.
- `TimerContext` remains the generic repeating timer for callers that need a
  simple interval; it is not used by the connection deadline path.
- Cross-worker wakeup: `App.arm_cluster_wakeup` (`src/router/app.zig:1136`)
  submits `xev.Async.wait` (`src/router/app.zig:1140`) with
  `on_cluster_wakeup` (`src/router/app.zig:1159`), which drains the cluster
  inbox and re-arms (`src/router/app.zig:1185`). Driven by `notify_cluster`
  (`src/router/app.zig:1149`) from any worker.
- `abort_if_expired` (`src/http/abort.zig:101`) converts a monotonic deadline
  into a cooperative abort. It is a helper for callers that own a clock; no
  runtime timer currently drives it.
- The QUIC deadline timer is in the UDP/QUIC section below.

## Async response completion

- `AsyncResponseState.arm` (`src/http/response.zig:92`) stores an
  `AsyncTarget` (`src/http/response.zig:66`) whose `complete_fn` and `wake_fn`
  fields are typed by `AsyncCompleteFn` (`src/http/response.zig:27`) and
  `AsyncWakeFn` (`src/http/response.zig:29`).
- HTTP/1: `invoke_handler` (`src/core/tcp.zig:734`) arms
  `async_response_state` at `src/core/tcp.zig:745` and
  `src/core/tcp.zig:750` with `async_target` (`src/core/tcp.zig:767`), pairing
  `complete_async_response` (`src/core/tcp.zig:775`) with
  `wake_async_dispatch` (`src/core/tcp.zig:790`).
- HTTP/2: `arm_http2_async` (`src/core/tcp.zig:538`) arms one slot per stream
  at `src/core/tcp.zig:548`, pairing `complete_http2_async_response`
  (`src/core/tcp.zig:555`) with `wake_http2_async_response`
  (`src/core/tcp.zig:581`); the wake is intentionally empty because HTTP/2
  reads stay armed.
- `AsyncResponse.complete_with_headers` (`src/http/response.zig:133`) checks
  the generation, calls `complete_fn` (`src/http/response.zig:147`), then
  `wake_fn` (`src/http/response.zig:155`). Driven by application code on the
  owning event loop; cross-thread completion must be marshalled first.
- `wake_async_dispatch` calls `resume_async_dispatch`
  (`src/core/tcp.zig:796`), which restores dispatch and re-arms the read.
  Cancellation is generation-based: `close_connection`
  (`src/core/tcp.zig:1317`) cancels the HTTP/1 slot and all HTTP/2 slots,
  `reset_protocol` (`src/core/tcp.zig:148`) resets the HTTP/2 slots, and pool
  acquire cancels the HTTP/1 slot (`src/router/app.zig:833`).

## UDP and QUIC

- `quic_transport.start` (`src/core/udp.zig:102`) arms the receive completion
  `on_read` (`src/core/udp.zig:168`) at `src/core/udp.zig:115` and the engine
  timer at `src/core/udp.zig:124`. Driven by a readable UDP socket.
- `on_read` feeds `engine.process_datagram` (`src/core/udp.zig:189`); a
  handler that starts shutdown mid-datagram leaves the completion disarmed.
- `quic_transport.close_socket` (`src/core/udp.zig:197`) cancels receive
  (`src/core/udp.zig:206` into `on_read_cancel`, `src/core/udp.zig:233`) and
  closes the socket (`src/core/udp.zig:224` into `on_close`,
  `src/core/udp.zig:247`). Windows closes synchronously
  (`src/core/udp.zig:217`).
- Engine timer: `start_timer` (`src/core/udp.zig:265`) registers `on_timer`
  (`src/core/udp.zig:293`) at `src/core/udp.zig:269`; the tick calls
  `engine.process` (`src/core/udp.zig:308`) and re-arms with
  `engine.next_timeout_ms` (`src/core/udp.zig:315`). `stop_timer`
  (`src/core/udp.zig:279`) cancels into `on_timer_cancel`
  (`src/core/udp.zig:323`). Driven by the lsquic earliest-advance tick
  (`src/quic/engine.zig:310`).
- lsquic interfaces are registered once by `engine.start`
  (`src/quic/engine.zig:156`): stream callbacks at
  `src/quic/engine.zig:187`, header-set callbacks at
  `src/quic/engine.zig:196`, packet-memory callbacks at
  `src/quic/engine.zig:202`, and the engine API at
  `src/quic/engine.zig:206`. lsquic invokes all of them synchronously from
  `process_datagram` (`src/quic/engine.zig:246`) and `process`
  (`src/quic/engine.zig:267`), never from a completion.
- Stream entry points: `on_new_connection` (`src/quic/engine.zig:360`),
  `on_connection_closed` (`src/quic/engine.zig:371`), `on_new_stream`
  (`src/quic/engine.zig:379`), `on_stream_read` (`src/quic/engine.zig:390`),
  `on_stream_write` (`src/quic/engine.zig:395`), `on_stream_close`
  (`src/quic/engine.zig:400`), and `on_header_set_available`
  (`src/quic/engine.zig:405`). All use `callconv(.c)` and forward to
  `QuicStream` methods.
- Header and packet hooks: `create_header_set` (`src/quic/engine.zig:419`),
  `prepare_header_decode` (`src/quic/engine.zig:434`), `process_header`
  (`src/quic/engine.zig:443`), `discard_header_set`
  (`src/quic/engine.zig:448`), `allocate_packet` (`src/quic/engine.zig:470`),
  and `release_packet` (`src/quic/engine.zig:483`).
- Transmit boundary: `packets_out` (`src/quic/engine.zig:453`) calls
  `api.send_packets` (`src/quic/engine.zig:459`), implemented at
  `src/quic/lsquic_api.zig:94` as a synchronous non-blocking send on the
  engine UDP socket; it queues no completion. `src/quic/lsquic_shim.c` only
  pins C struct layout ABI.

## Server lifecycle

- Startup: `App.init` creates the loop with `core_loop.init`
  (`src/router/app.zig:217`). `App.listen` and `App.listen_reuse_port` bind
  and call `accept_start` (`src/router/app.zig:900`,
  `src/router/app.zig:1126`); `App.listen_udp` starts the QUIC transport
  (`src/router/app.zig:924`).
- Run: `App.run` (`src/router/app.zig:933`) arms the cluster wakeup
  (`src/router/app.zig:939`) and enters `core_loop.run`
  (`src/router/app.zig:940`), which drives libxev `.until_done`
  (`src/core/loop.zig:83`).
- Shutdown request: `App.begin_shutdown` stops the timing-wheel scheduler,
  closes the listener
  (`src/router/app.zig:408`), shuts the QUIC transport down
  (`src/router/app.zig:409`), and calls `close_connection` for every active
  pool slot (`src/router/app.zig:413`).
- Drain: `App.drive_shutdown` (`src/router/app.zig:417`) runs the loop until
  every cancellation and close completion disarms, then
  `App.verify_shutdown` (`src/router/app.zig:425`) requires an empty pool, a
  completed listener close, and a drained QUIC transport. `App.deinit`
  (`src/router/app.zig:328`) panics if called from inside the loop
  (`src/router/app.zig:331`) and frees through the original allocator.
- Cluster: `Cluster.run` spawns and joins one `App` per worker thread through
  `src/router/worker_group.zig`; a worker failure records its index and original
  error before `Cluster.request_shutdown` notifies every worker through the
  async wakeup. `first_failure()` keeps that detail after `run` returns.

## TCP connection life cycle

```text
                 accept_start (tcp.zig:1593)
                        |
                        v
  listener.accept ---> on_accept_complete (tcp.zig:1644)
                        |
                        | server.on_connection
                        v
               on_new_connection (app.zig:790) ---> read_start (tcp.zig:1139)
                        |
                        v
  socket readable ---> on_read_complete (tcp.zig:1144)
                        |
          +-------------+-------------+
          | TLS                       | plaintext
          v                           v
  process_tls_data (tcp.zig:201)   route_decrypted_data (tcp.zig:286)
          |                           |
          +-------------+-------------+
                        v
         HTTP/1 route -> handler -> write_data_parts
         HTTP/2 receive -> dispatch
         WebSocket on_data
                        |
                        | start_write (tcp.zig:1015)
                        v
  socket writable --> on_write_complete (tcp.zig:1199)
                        |
                        | flush / pump_file_body / start_write
                        v
  close_after_flush or close_connection
                        |
                        | cancel read/write -> socket.close -> cancel and
                        | close callbacks
                        v
  release_closed_connection -> on_close_cb -> pool.release
```

## Outside the native loop

`src/core/transport.zig` exposes `protocol_core` and `driver` for the WASM edge
builds: the host loop calls `driver.read` and `driver.write` directly, so those
builds register no libxev completions. The C ABI drives the same protocol core
through an `App` (`src/c_api/app.zig:266`).
