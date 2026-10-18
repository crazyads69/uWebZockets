# Getting Started

This guide takes you from a checkout to a running server and points at the
right document for each next step. It assumes Zig 0.16.0.

## Install

With Nix installed, the shortest path is:

```sh
git clone https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
zig build hello_world -Doptimize=ReleaseSafe
```

In another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The first build fetches the pinned dependencies (BoringSSL, lsquic, libxev,
zslay, libdeflate, zlib) through Zig's package manager and compiles them with
Zig's own C/C++ toolchain. No CMake, Ninja, Go, Perl, Python, or system zlib is
required. Later builds reuse the caches.

## Use it in your own project

µWebZockets is a Zig package. Fetch a released tag or a full commit so
resolution stays reproducible:

```sh
zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag-or-commit>'
```

Wire it in `build.zig`:

```zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("uWebZockets", uz.module("uWebZockets"));
```

## Your first server

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

`uz.App(128)` is a bounded application type for 128 concurrent connections.
`init` performs one startup allocation that covers every connection, request
buffer, write queue, and message region for the lifetime of the process. The
request path never allocates.

## Add a route

```zig
fn greet(req: *uz.Request, res: *uz.Response) void {
    const name = req.get_param("name") orelse "world";
    var buffer: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "hello {s}", .{name}) catch return;
    res.text(body) catch {};
}

_ = try app.get("/greet/:name", greet);
```

Register routes before the first listener starts. Static routes win over
`:param` captures, and a terminal `*rest` captures the remaining path. See
[http.md](http.md) for routing, middleware, and the helper layer.

## Add a WebSocket route

```zig
fn on_open(socket: *uz.WebSocket) void {
    socket.send("welcome", false) catch {};
}

fn on_message(socket: *uz.WebSocket, message: []const u8, is_text: bool) void {
    if (is_text) socket.send(message, true) catch {};
}

_ = try app.ws("/echo", .{ .open = on_open, .message = on_message });
```

Incoming message slices are valid only for the callback. `send` returns
`error.WouldBlock` when the bounded write queue is full; use the `drain`
callback and `buffered_amount` to resume producers. See
[websocket.md](websocket.md).

## Add HTTPS

For production, pass real certificate files:

```zig
var app = try uz.App(128).init_https(init.io, "certs/fullchain.pem", "certs/privkey.pem");
```

For local development, generate an in-memory self-signed certificate:

```zig
var app = try uz.App(128).init_https_ephemeral(init.io);
```

`curl -k https://127.0.0.1:3443/` reaches the ephemeral listener. Client
certificates (mTLS) are covered in [tls.md](tls.md).

## Scale across cores

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

try group.listen("0.0.0.0", 3000);
try group.run();
```

Every worker owns its own loop and slab, shares the port through
`SO_REUSEPORT`, and is pinned to a physical core where the platform allows it.
See [architecture.md](architecture.md).

To terminate TLS in every worker, call `group.enable_https(...)` with PEM files,
or `group.enable_https_ephemeral()` for development, after `configure` and
before `listen`. Each worker owns its own TLS context; HTTP/3/QUIC clustering is
not supported. See [tls.md](tls.md#tls-enabled-clusters).

## Run the examples

| Step | Shows |
| --- | --- |
| `zig build hello_world` | Minimal HTTP/1.1 route on `App` |
| `zig build https_server` | HTTPS on port 3443 with an in-memory certificate |
| `zig build shared_nothing_cluster` | Four pinned workers, one slab each |
| `zig build tls_cluster` | Four TLS workers on port 8443 with per-worker certificates |
| `zig build basic_microservice` | `Presets.microservice` with JSON helpers |
| `zig build custom_builder` | Fluent overrides and the 50 MiB body path |
| `zig build chat_server` | WebSocket pub/sub with bounded topics |
| `zig build rpc_server` | Typed JSON-RPC procedures |
| `zig build http3_server` | HTTP/3 over QUIC with an in-memory certificate |

Every step appends `-Doptimize=ReleaseSafe` for production builds. Walkthroughs
live in [examples/readme_examples_test.md](../examples/readme_examples_test.md).

## Where to go next

- [api.md](api.md) for the full application surface.
- [deployment.md](deployment.md) for the production checklist.
- [client.md](client.md) to call other services from Zig.
- [memory_model.md](memory_model.md) to size capacities for your traffic.
- [roadmap.md](roadmap.md) for what is deliberately out of scope.

## First-run problems

| Symptom | Likely cause |
| --- | --- |
| `error.ApplicationUnavailable` | `run` called after `shutdown`, or a listener was never bound |
| `413` / `431` on large requests | `max_body_size` / header limits; see [troubleshooting.md](troubleshooting.md) |
| No terminal output from the dev log | stderr is not a terminal; set an explicit log file |
| `error.InvalidHostAddress` from the client | the client needs a numeric IP, not a hostname |
