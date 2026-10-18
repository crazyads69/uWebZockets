# µWebZockets 1.8.9 Examples

Build the supported examples with Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseSafe
```

The default install contains `hello_world`, `https_server`, `chat_server`,
`rpc_server`, `http3_server`, `basic_microservice`, `custom_builder`,
`shared_nothing_cluster`, `tls_cluster`, `h1spec`, and `autobahn_server` under
`zig-out/bin`.

These examples target the live `App` transports. The bounded HTTP/2/HPACK
components and the C ABI header are library surfaces rather than standalone
example servers.

## Use as a Zig dependency

µWebZockets is consumed as a normal Zig package. From a new project, fetch a
released tag or a full commit:

```sh
zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag-or-commit>'
```

Add the module to `build.zig`:

```zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("uWebZockets", uz.module("uWebZockets"));
```

A minimal `src/main.zig` is then:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a dependency") catch {};
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello);
    try app.listen("0.0.0.0", 3000);
    try app.run();
}
```

Run `zig build run` and verify with `curl http://127.0.0.1:3000/`. The rest of
the battery is on the same module: `app.ws(...)` for WebSocket, `app.rpc(...)`
for JSON-RPC, `app.static(...)` for assets, `build_cluster` for
thread-per-core workers, and `listen_udp` plus `init_http3` for HTTP/3. Run
`zig build lib` to install `zig-out/include/uWebZockets.h` for C and C++
consumers.

Pin tags or full commits rather than branches so dependency resolution stays
reproducible. The `tests/package_consumer` fixture compiles this snippet in CI.

## HTTP/1.1 server

Start the server:

```sh
./zig-out/bin/hello_world
```

Verify it from another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The expected result is `HTTP/1.1 200 OK` and the body `Hello from
µWebZockets! Zero allocation achieved.`

The equivalent build-and-run step is:

```sh
zig build hello_world -Doptimize=ReleaseSafe
```

## HTTPS server

`https_server` generates an ECDSA P-256 certificate in memory at startup, so
it needs no certificate files and no `openssl` step:

```sh
zig build https_server -Doptimize=ReleaseSafe
```

In another terminal, disable verification because the generated certificate is
not in any trust store:

```sh
curl -k -i https://127.0.0.1:3443/
```

The expected result is `HTTP/1.1 200 OK` and the body `hello from ephemeral
TLS`. The server speaks TLS 1.3, negotiates HTTP/2 when the client offers
`h2`, and embeds `localhost`, `127.0.0.1`, and `::1` in the certificate.
Generation runs once at startup and nothing touches the disk.
[docs/tls.md](../docs/tls.md) covers custom names, production PEM files, and
the C ABI equivalents.

## WebSocket pub/sub server

Start the server:

```sh
./zig-out/bin/chat_server
```

Connect two clients to the same bounded topic:

```sh
npx wscat -c ws://127.0.0.1:3000/chat
```

Text or binary messages sent by either client are published to the `global`
topic. The example reports subscription failure instead of silently continuing
when fixed pub/sub capacity is exhausted.

Message bytes are borrowed only until the callback returns. Copy into
application-owned bounded storage if work must outlive that callback.

The equivalent build-and-run step is:

```sh
zig build chat_server -Doptimize=ReleaseSafe
```

## JSON-RPC server

Start the typed JSON-RPC example:

```sh
./zig-out/bin/rpc_server
```

Call its `math.add` procedure from another terminal:

```sh
curl http://127.0.0.1:3000/rpc \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"math.add","params":{"left":2,"right":3},"id":1}'
```

The expected response is
`{"jsonrpc":"2.0","result":{"sum":5},"id":1}`. The equivalent
build-and-run step is:

```sh
zig build rpc_server -Doptimize=ReleaseSafe
```

## Terminal development log

Every example shows the development log by default when run in a terminal.
Start the hello-world server:

```sh
zig build hello_world -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/
```

The server prints the `µWEBZOCKETS` wordmark and a Vite-style ready summary
(`µWebZockets v1.8.9  ready in 0.6 ms`, then the `→ Local:` line, with the
elapsed time scaled from nanoseconds up) before the first accepting listener;
a one-line `µWebZockets` mark fits narrow terminals. Each request then logs
Vite-style as `HH:MM:SS | [METHOD] /path : STATUS` with a dim clock, cyan
method, and status-class color, alongside colored connection, WebSocket, and
metric lines. WebSocket examples add `ws` lines, and `App.log_metrics`
snapshots the Prometheus registry. Each worker thread renders and writes
records through its own `dev_log.Sink` as soon as they are recorded, so the
event loop never allocates. The default stderr sink stays quiet when stderr is
not a terminal, which keeps redirected runs and benchmarks fast;
`App.set_dev_log_file` binds an output that always records, and
`ServerConfig.enable_dev_log = false` silences the log.

## Capacity presets and custom builder

Start the microservice preset server on port 3000:

```sh
zig build basic_microservice -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/health
curl -i -X POST http://127.0.0.1:3000/echo -d '{"ping":true}'
```

The custom builder example on port 3001 reserves a 50 MiB request buffer per
connection inside one contiguous startup slab, prints the slab size, and
answers a body above the configured limit with a structured `413` document:

```sh
zig build custom_builder -Doptimize=ReleaseSafe
head -c 52428801 /dev/zero | curl -i -X POST http://127.0.0.1:3001/upload --data-binary @-
```

## Shared-nothing cluster

Start four workers that share one port through `SO_REUSEPORT`, each with its
own event loop, slabs, and pinned core where the platform allows it:

```sh
zig build shared_nothing_cluster -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/
```

The kernel load-balances accepted connections across the listeners, and every
connection stays inside the accepting worker's slab. See
[docs/architecture.md](../docs/architecture.md) for the affinity and tuning
details.

### TLS-enabled cluster

`tls_cluster` gives each of four workers its own TLS context and a distinct
self-signed certificate generated at startup:

```sh
zig build tls_cluster -Doptimize=ReleaseSafe
```

In another terminal:

```sh
curl -sk https://127.0.0.1:8443/
```

The body is `hello from a TLS worker group`. The enable call belongs after
`configure` and before `listen`:

```zig
var group = try uz.Server.builder(init.io)
    .with_max_clients(128)
    .build_cluster(std.heap.page_allocator, 4, .{});
defer group.deinit();

const Cluster = @TypeOf(group);
try group.configure(struct {
    fn routes(worker: *Cluster.Worker, index: usize) !void {
        _ = index;
        _ = try worker.get("/", hello);
    }
}.routes);

try group.enable_https_ephemeral();
try group.listen("0.0.0.0", 8443);
try group.run();
```

Use `enable_https("certs/fullchain.pem", "certs/privkey.pem")` in production;
`enable_https_ephemeral` is development-only and generates a different
certificate per worker. HTTP/3/QUIC clustering is not supported, and
`enable_https` does not configure client certificates. See
[docs/tls.md](../docs/tls.md#tls-enabled-clusters) for ownership, lifecycle,
and error names.

## Compliance targets

`autobahn_server` listens on port 9001 and accepts a 16 MiB echo message for
the external Autobahn fuzzing client. `h1spec` listens on port 8000 for the
vendored HTTP/1.1 suite. Use the GitHub workflows or the commands documented in
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md) so readiness checks and report gates
are applied consistently.

## HTTP/3 server

`http3_server` generates its certificate in memory with
`init_http3_ephemeral`, so it also runs with no certificate files:

```sh
zig build http3_server -Doptimize=ReleaseSafe
./zig-out/bin/http3_server
```

The server listens for QUIC on UDP port 8443 and routes `GET /` through the
same `Request` and `Response` API as HTTP/1.1. A client with HTTP/3 support can
request `https://127.0.0.1:8443/`, for example
`curl --http3 -k https://127.0.0.1:8443/` when the installed curl was built
with HTTP/3 support. The certificate is self-signed, so skip verification or
configure trust for local development.

The example uses a capacity of 128 connections/active streams. QPACK headers,
request bodies, response metadata, response bodies, and outgoing UDP packets
all use fixed startup-allocated pools. The UDP socket, timer, cancellation, and
close completions are owned by `src/core/udp.zig` and drain before application
storage is released.

The live example serves bounded HTTP/3 request/response streams and rejects
extended CONNECT. RFC 9220 and WebTransport draft-16 validators and wire
helpers are Zig library surfaces only; they are not connected to the lsquic
listener. The HTTP/3 compliance gate exercises standard HTTP/3
request/response routing.
