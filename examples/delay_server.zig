const std = @import("std");
const uz = @import("uWebZockets");

/// Largest delay the example accepts; keeps parked requests bounded.
const max_delay_ms: u64 = 60_000;

fn parse_delay(raw: []const u8) ?u64 {
    if (raw.len == 0) return null;
    const value = std.fmt.parseInt(u64, raw, 10) catch return null;
    return @min(value, max_delay_ms);
}

fn delay_handler(req: *uz.Request, token: uz.AsyncResponse) void {
    const delay = parse_delay(req.get_param("ms") orelse "");
    if (delay == null) {
        token.complete("400 Bad Request", "Invalid delay") catch |err| {
            std.log.err("delay response failed: {}", .{err});
        };
        return;
    }

    // The response fields are static, so the parked request needs no
    // allocation while it waits on the worker's timing wheel.
    token.sleep_complete(
        delay.?,
        "200 OK",
        "Content-Type: text/plain\r\n",
        "delayed response",
    ) catch |err| {
        token.complete("500 Internal Server Error", @errorName(err)) catch |complete_err| {
            std.log.err("delay response failed: {} (after {})", .{ complete_err, err });
        };
    };
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.route_async(.get, "/delay/:ms", delay_handler);

    try app.listen("0.0.0.0", 3000);
    try app.run();
}
