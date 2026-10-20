const std = @import("std");
const c = @import("c");
const xev = @import("xev");
const support = @import("test_support");

const Router = support.radix.Router;

const FakeEngine = struct {
    const Self = @This();

    expected_address: ?*Self = null,
    start_count: usize = 0,

    pub fn init() !Self {
        return .{};
    }

    pub fn start(
        self: *Self,
        _: *c.SSL_CTX,
        _: *const Router,
        _: std.posix.socket_t,
        _: std.Io.net.IpAddress,
    ) !void {
        self.start_count += 1;
        if (self.expected_address != self) return error.EngineMoved;
        return error.TestStop;
    }

    pub fn deinit(_: *Self) void {}

    pub fn process_datagram(_: *Self, _: []const u8, _: std.Io.net.IpAddress) void {}

    pub fn process(_: *Self) void {}

    pub fn next_timeout_ms(_: *const Self) u64 {
        return 1000;
    }

    pub fn cooldown(_: *Self) void {}
};

test "udp: segmented send preserves two equal datagrams" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const sender = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    if (sender < 0) return error.SkipZigTest;
    defer _ = std.posix.system.close(sender);
    const receiver = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    if (receiver < 0) return error.SkipZigTest;
    defer _ = std.posix.system.close(receiver);

    var destination: std.posix.sockaddr.in = .{
        .family = std.posix.AF.INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
        .zero = [_]u8{0} ** 8,
    };
    if (std.c.bind(
        receiver,
        @ptrCast(&destination),
        @sizeOf(std.posix.sockaddr.in),
    ) != 0) return error.SkipZigTest;

    var length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.c.getsockname(receiver, @ptrCast(&destination), &length) != 0) {
        return error.SkipZigTest;
    }
    var timeout = std.posix.timeval{ .sec = 1, .usec = 0 };
    std.posix.setsockopt(
        receiver,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch return error.SkipZigTest;

    var first: [4]u8 = "aaaa".*;
    var second: [4]u8 = "bbbb".*;
    var first_iov = [_]c.struct_iovec{.{ .iov_base = &first, .iov_len = first.len }};
    var second_iov = [_]c.struct_iovec{.{ .iov_base = &second, .iov_len = second.len }};
    var specs = [_]c.lsquic_out_spec{
        .{
            .iov = &first_iov,
            .iovlen = 1,
            .dest_sa = @ptrCast(&destination),
        },
        .{
            .iov = &second_iov,
            .iovlen = 1,
            .dest_sa = @ptrCast(&destination),
        },
    };

    try std.testing.expectEqual(
        @as(c_int, 2),
        support.quic_api.send_packets(sender, &specs, specs.len),
    );

    var received: [8]u8 = undefined;
    const first_len = std.c.recvfrom(receiver, &received, first.len, 0, null, null);
    try std.testing.expectEqual(@as(isize, 4), first_len);
    try std.testing.expectEqualStrings("aaaa", received[0..4]);
    const second_len = std.c.recvfrom(receiver, &received, second.len, 0, null, null);
    try std.testing.expectEqual(@as(isize, 4), second_len);
    try std.testing.expectEqualStrings("bbbb", received[0..4]);
}

test "udp: QUIC engine starts only after transport reaches stable storage" {
    const Transport = support.udp.quic_transport(FakeEngine);
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    const ssl_ctx: *c.SSL_CTX = @ptrFromInt(1);
    var transport = try Transport.init(ssl_ctx, &router, "127.0.0.1", 0);
    defer transport.deinit();

    try std.testing.expectEqual(@as(usize, 0), transport.engine.start_count);
    transport.engine.expected_address = &transport.engine;

    var loop: xev.Loop = undefined;
    try std.testing.expectError(error.TestStop, transport.start(&loop));
    try std.testing.expectEqual(@as(usize, 1), transport.engine.start_count);
}
