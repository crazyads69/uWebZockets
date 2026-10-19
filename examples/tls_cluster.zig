//! TLS-enabled shared-nothing worker group: one libxev loop and one TLS
//! context per core.
//!
//! Build and run:
//!   zig build tls_cluster -Doptimize=ReleaseSafe
//!   curl -sk https://127.0.0.1:8443/
//!
//! Optional environment overrides:
//!   UWZ_MODE          tls-cluster (default), plaintext-cluster, or tls-single
//!   UWZ_TLS_BIND      listen address (default 0.0.0.0)
//!   UWZ_TLS_PORT      listen port (default 8443)
//!   UWZ_WORKERS       worker count: 1, 2, 4, or 8 (default 4)
//!   UWZ_MAX_CLIENTS   connection capacity: 128, 1024, or 2048 (default 128)
//!   UWZ_CPU_AFFINITY  1 to pin workers to physical cores, 0 to leave them
//!                     unpinned for SMT benchmark hosts (default 1)
//!   UWZ_TLS_CERT      PEM certificate path, paired with UWZ_TLS_KEY
//!   UWZ_TLS_KEY       PEM private key path, paired with UWZ_TLS_CERT
//!
//! The derived benchmark contract uses the three modes as controls. Without
//! credential variables the cluster modes generate one ephemeral self-signed
//! certificate each, which is development-only; the single-application TLS
//! control always requires the PEM files. Each worker terminates TLS on the
//! same SO_REUSEPORT port with its own context, so no handshake state or
//! session cache is shared between loops.

const std = @import("std");
const uz = @import("uWebZockets");

/// Listener shape used by the scaling contract controls.
const Mode = enum {
    tls_cluster,
    plaintext_cluster,
    tls_single,
};

/// Parsed environment overrides for one example run.
const Options = struct {
    mode: Mode = .tls_cluster,
    bind: []const u8 = "0.0.0.0",
    port: u16 = 8443,
    workers: usize = 4,
    max_clients: usize = 128,
    cpu_affinity: bool = true,
    certificate: ?[]const u8 = null,
    private_key: ?[]const u8 = null,
};

fn parse_mode(value: []const u8) !Mode {
    if (std.mem.eql(u8, value, "tls-cluster")) return .tls_cluster;
    if (std.mem.eql(u8, value, "plaintext-cluster")) return .plaintext_cluster;
    if (std.mem.eql(u8, value, "tls-single")) return .tls_single;
    return error.InvalidEnvironmentValue;
}

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a TLS worker group") catch |err| {
        std.log.err("response failed: {}", .{err});
    };
}

fn parse_env_usize(environ: *const std.process.Environ.Map, name: []const u8) !?usize {
    const raw = environ.get(name) orelse return null;
    return std.fmt.parseInt(usize, raw, 10) catch error.InvalidEnvironmentValue;
}

fn read_options(environ: *const std.process.Environ.Map) !Options {
    var options = Options{};
    if (environ.get("UWZ_MODE")) |value| options.mode = try parse_mode(value);
    if (environ.get("UWZ_TLS_BIND")) |value| options.bind = value;
    if (environ.get("UWZ_TLS_PORT")) |value| {
        options.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidEnvironmentValue;
    }
    if (try parse_env_usize(environ, "UWZ_WORKERS")) |workers| options.workers = workers;
    if (try parse_env_usize(environ, "UWZ_MAX_CLIENTS")) |clients| options.max_clients = clients;
    if (environ.get("UWZ_CPU_AFFINITY")) |value| {
        if (std.mem.eql(u8, value, "1")) {
            options.cpu_affinity = true;
        } else if (std.mem.eql(u8, value, "0")) {
            options.cpu_affinity = false;
        } else {
            return error.InvalidEnvironmentValue;
        }
    }
    options.certificate = environ.get("UWZ_TLS_CERT");
    options.private_key = environ.get("UWZ_TLS_KEY");
    if ((options.certificate == null) != (options.private_key == null)) {
        return error.IncompleteTlsCredentials;
    }
    return options;
}

fn log_worker_metrics(worker_index: usize, registry: ?*uz.metrics.Registry) void {
    const counters = registry orelse return;
    std.log.info("worker_accepts index={d} accepted={d} closed={d}", .{
        worker_index,
        counters.get(.connections_accepted),
        counters.get(.connections_closed),
    });
}

fn serve_cluster(
    comptime workers: usize,
    comptime max_clients: usize,
    init: std.process.Init,
    options: Options,
) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(max_clients)
        .with_observability(true)
        .build_cluster(std.heap.page_allocator, workers, .{
        .cpu_affinity = options.cpu_affinity,
    });
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Cluster.Worker, worker_index: usize) !void {
            _ = worker_index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    switch (options.mode) {
        .tls_cluster => {
            if (options.certificate) |certificate| {
                const arena = init.arena.allocator();
                const cert_path = try arena.dupeZ(u8, certificate);
                const key_path = try arena.dupeZ(u8, options.private_key.?);
                try group.enable_https(cert_path, key_path);
            } else {
                try group.enable_https_ephemeral();
            }
        },
        .plaintext_cluster => {
            if (options.certificate != null) return error.CredentialsRequireTlsMode;
        },
        .tls_single => return error.WrongListenerMode,
    }

    try group.catch_shutdown_signals();
    try group.listen(options.bind, options.port);
    try group.run();
    for (0..workers) |index| {
        const app_worker = group.worker(index) orelse continue;
        log_worker_metrics(index, app_worker.metrics());
    }
}

fn serve_single(
    comptime max_clients: usize,
    init: std.process.Init,
    options: Options,
) !void {
    const certificate = options.certificate orelse return error.MissingTlsCredentials;
    const private_key = options.private_key orelse return error.MissingTlsCredentials;
    const arena = init.arena.allocator();
    const cert_path = try arena.dupeZ(u8, certificate);
    const key_path = try arena.dupeZ(u8, private_key);

    var application = try uz.App(max_clients).init_https(init.io, cert_path, key_path);
    defer application.deinit();

    _ = try application.get("/", hello);
    try application.catch_shutdown_signals();
    try application.listen(options.bind, options.port);
    try application.run();
}

fn dispatch_clients(
    comptime workers: usize,
    init: std.process.Init,
    options: Options,
) !void {
    switch (options.max_clients) {
        128 => try dispatch_mode(workers, 128, init, options),
        256 => try dispatch_mode(workers, 256, init, options),
        512 => try dispatch_mode(workers, 512, init, options),
        1024 => try dispatch_mode(workers, 1024, init, options),
        2048 => try dispatch_mode(workers, 2048, init, options),
        else => return error.UnsupportedMaxClients,
    }
}

fn dispatch_mode(
    comptime workers: usize,
    comptime max_clients: usize,
    init: std.process.Init,
    options: Options,
) !void {
    if (options.mode == .tls_single) {
        if (workers != 1) return error.SingleModeRequiresOneWorker;
        return serve_single(max_clients, init, options);
    }
    return serve_cluster(workers, max_clients, init, options);
}

pub fn main(init: std.process.Init) !void {
    const options = try read_options(init.environ_map);
    switch (options.workers) {
        1 => try dispatch_clients(1, init, options),
        2 => try dispatch_clients(2, init, options),
        4 => try dispatch_clients(4, init, options),
        8 => try dispatch_clients(8, init, options),
        else => return error.UnsupportedWorkerCount,
    }
}
