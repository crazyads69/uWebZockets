# Operations

Build, integration, verification, and release operations for µWebZockets. See
the [README](../README.md) for the quick start and the other
[docs](architecture.md) for runtime behavior.

## Requirements

- Zig 0.16.0
- A build target: Linux or macOS are supported; Windows has native compile and
  runtime jobs; FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD are community targets
  (see [Platform support](#platform-support))
- The `vendor/h1spec` submodule pinned to `farbenbuilds/h1spec` for the h1spec development suite

Zig fetches and compiles BoringSSL, lsquic, ls-qpack, ls-hpack, libdeflate, and
zlib itself. No CMake, Ninja, Go, Perl, Python, `patch`, or system zlib
installation is required. The first build downloads the pinned packages through
Zig's package manager into the global and local caches, so later builds need no
re-fetch. The Nix flake pins Nixpkgs 26.05 and provides the supported Zig
toolchain on all release architectures.

## Build

```sh
git clone https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

Add `--recurse-submodules` to the clone when running the h1spec compliance
target.

The root `build.zig` only injects the graph. Target, vendor, sanitizer, test,
fuzz, and example construction lives in focused modules under `builds/`.
Build the edge and kernel-bypass artifacts explicitly:

```sh
zig build wasm-freestanding -Doptimize=ReleaseSafe
zig build wasm-wasi -Doptimize=ReleaseSafe
zig build ebpf
zig build all-targets -Doptimize=ReleaseSafe
```

The freestanding target exports linear memory for V8 isolate hosts. Both WASM
targets export bounded `alloc`/`free` and generation-checked handle functions;
host code should retain each handle while its shared-memory view is live and
release it exactly once. The eBPF step emits
`zig-out/share/uwebzockets/uwz_xdp.o` for the XSK redirect and
`zig-out/share/uwebzockets/uwz_latency.o` for the per-CPU packet-length
histogram served by the hidden `/metrics` endpoint when the map is pinned at
`/sys/fs/bpf/uwz_latency`. Attaching the redirect, pinning the histogram, and
populating the XSK map require Linux network-administration privileges. The
server data path never attaches the XSK redirect: requesting
`ServerConfig.transport = .kernel_bypass` reports `.standard` with reason
`.data_path_unwired`. Applications that want AF_XDP drive `uz.xdp_transport`
and `uz.xdp` directly. The hidden `/metrics` endpoint still reads the pinned
latency histogram.

### Sanitizers

The Nix shell exposes a coherent LLVM sanitizer runtime, matching glibc, and
dynamic linker. Run the complete test graph with ASan, UBSan, LeakSanitizer,
Zig C-UB checks, and frame pointers:

```sh
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
```

Run the separate x86_64 Linux MemorySanitizer dependency-boundary smoke with
origin tracking:

```sh
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
```

Address/undefined sanitizer mode and MemorySanitizer mode are mutually
exclusive. The ASan/UBSan mode runs the centralized test and C ABI graph while
instrumenting the pinned C/C++ libraries and local C shim. The MSan mode
rebuilds those components with origin tracking and executes a focused C
dependency-boundary smoke; it does not instrument Zig code or run the complete
C ABI suite. Both modes use isolated vendor caches and run as separate CI steps.
Threaded tests, including the cluster TLS lifecycle tests, run under ASan with
`use_sigaltstack=0`: ASan installs an alternate signal stack per thread and
unmaps whichever stack it finds on thread teardown, while Zig 0.16's
thread-local stack is not page aligned. Leak detection, `halt_on_error`, and
every other check stay enabled; only the deep-stack-overflow reporting path
changes.

Outside Nix, also pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. If
that runtime requires a different glibc than the host, pass the matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths together.
Sanitizer builds are restricted to native Linux, set coherent runtime RPATHs,
and use a separate vendor cache.

### Fuzzing

`zig build test` runs the ordinary unit suite from `src/tests/main.zig`;
production modules never import that suite. Protocol fuzzing has two layers:

```sh
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe
zig build oss-fuzz-smoke -Doptimize=ReleaseSafe
```

The Smith harness retains HTTP, query/Accept, zslay, extension-negotiation,
HPACK, multipart, and HTTP/3 validation coverage. The OSS-Fuzz objects export
`LLVMFuzzerTestOneInput` for HTTP framing, WebSocket masking, query parsing,
cookie parsing, and QUIC/WebTransport packet boundaries. Zig's `-ffuzz`
instrumentation emits inline-8bit-counter sections rather than the
trace-pc-guard callbacks current libFuzzer runtimes reject;
`oss-fuzz/zig_sancov_shim.c` registers those sections with libFuzzer at link
time. `zig build oss-fuzz-objects` fails when an object lacks
`__sancov_cntrs`, and `oss-fuzz-smoke` runs deterministic seeds
without libFuzzer. A reusable ClusterFuzzLite workflow links and executes
all five targets with the OSS-Fuzz ASan/libFuzzer environment on the exact
revision under test. This is an OSS-Fuzz compatibility gate, not a claim of
enrollment in the hosted service; `oss-fuzz/README.md` documents the Zig
sanitizer boundary.

### Cross targets

Without Nix, install Zig 0.16.0 and run the same Zig commands. The bundled zlib
package compiles for the selected target, so cross builds need no external
zlib prefix. A musl cross build is one command:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

Windows builds use the same package and require no MinGW zlib installation.
The native workflow compiles the test and ABI graph and runs the suite. The
compile commands are:

```powershell
zig build test-compile -Dtarget=x86_64-windows-gnu `
  -Doptimize=ReleaseSafe --summary all
zig build lib -Dtarget=x86_64-windows-gnu `
  -Doptimize=ReleaseFast --summary all
```

`zig build lib -Doptimize=ReleaseFast` installs the µWebZockets, BoringSSL,
lsquic, libdeflate, and zlib static archives under `zig-out/lib`. Applications
that link these archives directly must also link libc, the C++ runtime, the
installed `libz.a`, and the platform networking libraries required by those
dependencies (on Windows: `ws2_32`, `mswsock`, `crypt32`, and `advapi32`).

## Development log

The terminal development log is on by default and allocation-free. Run any
example in a terminal:

```sh
zig build chat_server -Doptimize=ReleaseSafe
```

```zig
var server = try uz.Server.builder(init.io)
    .with_observability(true)
    .build(std.heap.page_allocator);
defer server.deinit();
```

The exact `µWEBZOCKETS` wordmark and a Vite-style ready summary are written
once at startup, before the first accepting listener: the version with the
elapsed startup time, then the `→ Local:` line. A
terminal narrower than the block art gets a one-line `µWebZockets` mark
instead, and builds without the development log keep the plain
`server listening` std.log line. HTTP/1.1 and HTTP/2 requests log Vite-style as
`HH:MM:SS | [METHOD] /path : STATUS` with a dim clock, cyan method, and
status-class color. Connection, WebSocket, and metric events follow with a
colored direction badge. Every worker thread owns one `dev_log.Sink`; each
record is rendered into its fixed 4096-byte buffer and written immediately, so
the terminal reflects events in real time and the event loop never allocates.
A metric snapshot goes out as one batch. The width probe in
`src/observability/terminal.zig` is best effort: redirected output keeps the
full wordmark. Lines that cannot fit and failed or short writes are dropped and
counted in `Sink.dropped` rather than retried.

With `watch_paths` configured, the app arms a watcher before the loop starts:
`with_dev_log(true)` plus `with_watch_paths(&.{"src"})` logs
`watch modified src/router/app.zig` for every save, plus created and deleted
lines for renames and removals. Linux reads an inotify descriptor through the
event loop, so changes are real time and the idle loop stays blocked; other
targets walk the roots on a 500 ms loop timer and diff modification time and
size. Both backends are bounded and never allocate per event, and both skip
build and VCS directories.

Records carry an explicit direction (`data_in` or `data_out`) and a named event
payload; there is no ambient logger state. `ServerConfig.enable_dev_log`
defaults on, but the default stderr sink stays quiet when stderr is not a
terminal so redirected runs are not slowed; `false` silences the wordmark,
request lines, metric snapshots, and every other development-log write, while
an explicit `App.set_dev_log_file` always records. `App.flush_dev_log` writes
any pending bytes, and `App.log_metrics` records every counter of the bounded
Prometheus registry. The `uwz_connections_accepted`, `uwz_connections_closed`,
`uwz_http_requests`, and `uwz_ws_messages` counters advance when observability
is enabled on TCP transports. HTTP/2 dispatch emits the same request records as
HTTP/1.1 and advances the `uwz_http_requests` counter; HTTP/3 emits one
`http_request` record per completed request/response through the owning
thread's sink, while the QUIC path never advances the counter registry.

## Graceful shutdown

Applications that should stop on SIGINT or SIGTERM arm the watcher before the
loop starts:

```zig
var server = try uz.Server.builder(init.io)
    .build(std.heap.page_allocator);
defer server.deinit();

try server.catch_shutdown_signals();
try server.listen("127.0.0.1", 3000);
try server.run();
```

`catch_shutdown_signals` moves the application into the same `begin_shutdown`
path as an explicit `shutdown()` call: existing connections drain, recurring
timers stop, and the loop exits. It must be called before `run`; once shutdown
has started it returns `error.ApplicationUnavailable`. A second call returns
`error.SignalWatcherAlreadyInstalled`, because the signal disposition and
self-pipe are process-wide and only one watcher may own them.

On POSIX, SIGINT and SIGTERM handlers write one byte into a non-blocking
self-pipe that the event loop polls. Signals arriving before the loop drains
coalesce into a single shutdown request, no handler allocates or logs, and
`deinit` restores the previous dispositions. Windows installs a
`SetConsoleCtrlHandler` routine for Ctrl+C, console close, and logoff/shutdown
events; it records the request in a process flag and wakes the loop through a
libxev async.

## Use as a Zig dependency

### Zig package manager

From the consuming project, fetch an immutable release tag or commit:

```sh
zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag-or-commit>'
```

This adds the package under the `uWebZockets` name. Import it from `build.zig`:

```zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
const uz_module = uz.module("uWebZockets");
exe.root_module.addImport("uWebZockets", uz_module);
```

Pin a tag or full commit rather than a moving branch so dependency resolution
stays reproducible.

### Local path dependency

```sh
git submodule add https://github.com/farbenbuilds/uWebZockets.git vendor/uWebZockets
git -C vendor/uWebZockets checkout <release-tag-or-full-commit-hash>
git add .gitmodules vendor/uWebZockets
```

```zig
// build.zig.zon
.dependencies = .{
    .uWebZockets = .{ .path = "vendor/uWebZockets" },
},
```

The package manifest fetches zslay, libxev, BoringSSL, lsquic, ls-qpack,
ls-hpack, and libdeflate from immutable URLs or commits with Zig package
hashes, so a downstream path dependency does not need the h1spec submodule. The
public module carries native link metadata, orders dependency builds, and
supplies the C shim through its clean static-library edge. The
`tests/package_consumer` fixture compiles the README Quick Start snippet in CI
against the release module surface, so the documented `zig fetch` and
`build.zig` wiring cannot drift.

## C ABI

The package includes [`include/uWebZockets.h`](../include/uWebZockets.h), and
both `zig build install` and `zig build lib` install it as
`zig-out/include/uWebZockets.h` by default.

- Opaque handles, `uwz_slice` byte views, and a versioned `uwz_error` mapping.
- `uwz_app_create`, `uwz_app_shutdown`, and `uwz_app_destroy` make ownership
  explicit; destroy nulls the caller's handle. `uwz_app_create_tls_ephemeral`
  and `uwz_app_create_http3_ephemeral` create development applications from an
  in-memory self-signed certificate; [tls.md](tls.md) explains when to use
  them and when to pass PEM paths instead.
- Shutdown requested from a callback is drained by the active `uwz_app_run`
  call. Destroying from a callback returns `UWZ_ERROR_INVALID_STATE` and leaves
  the handle valid for destruction after the run returns.
- Fixed capacities: 1,024 connections and 64 copied route paths.
- Request fields or parameters needed after a C callback returns must be copied
  into caller-owned storage; WebSocket message slices are callback-scoped.
- Async tokens are copyable, generation-checked values completed exactly once
  on the owning event loop.

The ABI covers the high-level server operations above. It is not a one-to-one
binding for compile-time Zig configuration types or the low-level `udp`,
HTTP/2, HPACK, HTTP/3-extension, and WebTransport helper modules exported from
`src/root.zig`; those surfaces remain Zig-only.

## Performance contract

The versioned
[`http-throughput-v1`](../benchmarks/http_throughput_guarantee.md) contract
compares three same-runner `wrk` samples for a pull request and its base
revision. The candidate median must remain at least 90 percent of the baseline
median. Scheduled and manual mainline runs append structured records and raw
evidence to the `benchmark-data` branch. This is a relative regression
guarantee, not an absolute requests-per-second claim across hardware or
toolchain cohorts.

## Platform support

- Supported: Linux and macOS on `x86_64` and `aarch64`. Linux runs the hosted
  runtime and sanitizer matrix; the macOS test graph cross-compiles on demand,
  but no hosted macOS runner executes kqueue. Runtime coverage is tracked in
  the roadmap.
- Native Windows coverage: `x86_64-windows-gnu` has a reusable workflow that
  compiles the test and C ABI graph, builds the ReleaseFast libraries, and runs
  `zig build test` on `windows-2025`. The 1.9.0 accept and queued-close fixes
  are recorded in
  [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md). Official support
  follows a green runtime job for the release commit; no Windows binaries are
  published. Windows QUIC uses IOCP UDP receives and Winsock `WSASendTo`
  sends.
- Community: FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD share the build graph
  without dedicated CI.

Releases are source tags; no per-platform binary archives are built or
uploaded, and developers fetch the tag with `zig fetch`.

Shared-nothing clustering is fully supported on Linux. macOS runs workers
without hard pinning because the platform exposes no affinity API. See
[architecture.md](architecture.md#windows-fallback).

Request fields, route captures, middleware, async tokens, and transport pools
have fixed capacities; there is no dynamic overflow fallback.

## Release metadata

The release version is single-sourced in `src/version.zig`, which `build.zig`
derives from. `build.zig.zon`, `flake.nix`, `include/uWebZockets.h`, and the
changelog repeat it because their consumers do not execute Zig code.
`scripts/check_release_version.sh` verifies every copy, the C++ header
assertions, the C smoke test, and the documentation headers together.
