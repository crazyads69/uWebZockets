//! TLS-enabled shared-nothing worker group: one libxev loop and one TLS
//! context per core.
//!
//! Build and run:
//!   zig build tls_cluster -Doptimize=ReleaseSafe
//!   curl -sk https://127.0.0.1:8443/
//!
//! Each worker terminates TLS on the same SO_REUSEPORT port with its own
//! context, so no handshake state or session cache is shared between loops.
//! The self-signed certificates are generated per worker at startup and are
//! development-only.

const std = @import("std");
const uz = @import("uWebZockets");

const worker_count = 4;

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a TLS worker group") catch {};
}

pub fn main(init: std.process.Init) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .build_cluster(std.heap.page_allocator, worker_count, .{});
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Cluster.Worker, worker_index: usize) !void {
            _ = worker_index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    // Production deployments load real PEM files instead:
    // try group.enable_https("certs/fullchain.pem", "certs/privkey.pem");
    try group.enable_https_ephemeral();

    try group.listen("0.0.0.0", 8443);
    try group.run();
}
