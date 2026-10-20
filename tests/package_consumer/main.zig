//! Compiles the README Quick Start snippet against the package module surface.
//!
//! `zig build check` proves a downstream consumer can fetch the package,
//! import `uWebZockets`, and build a real `App` with a route, listener, and
//! run call.

const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a dependency") catch {};
}

/// Compiles the documented cluster lifecycle without starting a server.
fn cluster_surface(init: std.process.Init, allocator: std.mem.Allocator) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(8)
        .build_cluster(allocator, 4, .{});
    defer group.deinit();

    const Group = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Group.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
            _ = try worker.trace("/probe", hello);
        }
    }.routes);
    try group.enable_https_ephemeral();
    try group.listen("127.0.0.1", 0);
    try group.catch_shutdown_signals();
}

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("UWZ_PACKAGE_CONSUMER_CLUSTER") != null) {
        try cluster_surface(init, std.heap.page_allocator);
    }

    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello);
    try app.listen("0.0.0.0", 3000);
    try app.run();
}
