const std = @import("std");
const builtin = @import("builtin");
const support = @import("test_support");
const context = support.context;
const loop = support.loop;
const pool_mod = support.pool;
const tcp = support.tcp;
const timer = support.timer;
const zero_copy = support.zero_copy;
const WebSocket = support.ws_socket.WebSocket;

// test generic bitset pool logic.
test "core: bitset pool acquires and releases slots" {
    var pool = context.bitset_pool(usize, 10).init();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test generic freelist pool logic.
test "core: freelist pool acquires and releases slots" {
    var pool = try pool_mod.freelist_pool(usize, 10).init();
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test loop initialization and deinitialization.
test "core: loop init and deinit" {
    var l = try loop.init();
    defer loop.deinit(&l);

    // ensure the underlying xev loop is available by taking its pointer.
    const xev_loop = l.get_xev_loop();
    _ = xev_loop;
}

fn dummy_accept(socket: @import("xev").TCP, user_data: ?*anyopaque) void {
    _ = socket;
    _ = user_data;
}

// test tcp server initialization.
test "core: tcp listener port supports IPv6" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const server = tcp.init_server("::1", 0, dummy_accept, null) catch
        return error.SkipZigTest;
    defer tcp.close_socket(@import("xev").tcp_fd(server.listener));
    try std.testing.expect(try tcp.listener_port(&server) != 0);
}

test "core: tcp server init" {
    // bind to ephemeral port 0 to prevent port collisions during tests.
    const server = try tcp.init_server("127.0.0.1", 0, dummy_accept, null);
    defer tcp.close_socket(@import("xev").tcp_fd(server.listener));
}

// dummy callback for timer test.
fn dummy_tick() void {}

// test timer initialization and deinitialization.
test "core: timer init and deinit" {
    var t = try timer.init_timer(100, dummy_tick);
    defer timer.deinit_timer(&t);
}

test "tcp: accept retry delay backs off to a bounded ceiling" {
    try std.testing.expectEqual(@as(u64, 0), tcp.accept_retry_delay_ms(0));
    try std.testing.expectEqual(@as(u64, 0), tcp.accept_retry_delay_ms(1));
    try std.testing.expectEqual(@as(u64, 1), tcp.accept_retry_delay_ms(2));
    try std.testing.expectEqual(@as(u64, 2), tcp.accept_retry_delay_ms(3));
    try std.testing.expectEqual(@as(u64, 512), tcp.accept_retry_delay_ms(11));
    try std.testing.expectEqual(tcp.accept_retry_max_ms, tcp.accept_retry_delay_ms(12));
    try std.testing.expectEqual(tcp.accept_retry_max_ms, tcp.accept_retry_delay_ms(255));
}

test "core: accept failures arm and drain a bounded retry timer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer _ = std.posix.system.close(pair[1]);

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);

    var server = tcp.TcpServer{
        .accept_retry_timer = try @import("xev").Timer.init(),
        .listener = @import("xev").TCP.initFd(pair[0]),
        .on_connection = dummy_accept,
        .user_data = null,
    };

    tcp.accept_start(&server, &event_loop);
    if (std.c.write(pair[1], "x", 1) != 1) return error.SkipZigTest;

    // A non-listening socket makes accept fail. The first failure rearms; a
    // second consecutive failure must disarm accept and arm the timer.
    var attempts: usize = 0;
    while (!server.accept_retry_active and attempts < 4) : (attempts += 1) {
        try event_loop.xev_loop.run(.once);
    }
    try std.testing.expect(server.accept_retry_active);
    try std.testing.expect(server.accept_fail_streak >= 2);
    try std.testing.expect(server.accept_completion.state() != .active);

    tcp.close_server(&server, &event_loop);
    try event_loop.xev_loop.run(.until_done);
    try std.testing.expect(server.close_complete);
    try std.testing.expect(!server.accept_retry_active);
    try std.testing.expect(!server.accept_retry_cancel_active);
    tcp.deinit_server(&server);
}

test "tcp: multipart ring writes preserve order across wrap" {
    var buffer = [_]u8{0} ** 8;
    const tail = tcp.copy_parts_to_ring(&buffer, 6, &.{ "ab", "cde" });

    try std.testing.expectEqual(@as(usize, 3), tail);
    try std.testing.expectEqualStrings("cde", buffer[0..3]);
    try std.testing.expectEqualStrings("ab", buffer[6..8]);
}

test "tcp: HTTP/2 frame capacity reserves plaintext and TLS overhead" {
    try std.testing.expectEqual(@as(usize, 0), tcp.http2_frame_payload_capacity(9, false));
    try std.testing.expectEqual(@as(usize, 1), tcp.http2_frame_payload_capacity(10, false));

    const tls_fixed_cost = 9 + 2 * 64;
    try std.testing.expectEqual(
        @as(usize, 0),
        tcp.http2_frame_payload_capacity(tls_fixed_cost, true),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        tcp.http2_frame_payload_capacity(tls_fixed_cost + 1, true),
    );
    try std.testing.expectEqual(
        @as(usize, 16 * 1024),
        tcp.http2_frame_payload_capacity(tls_fixed_cost + 32 * 1024, true),
    );
}

test "tcp: drained write ring normalizes its head" {
    try std.testing.expectEqual(@as(usize, 0), tcp.advance_write_head(65_504, 32, 0, 65_536));
    try std.testing.expectEqual(@as(usize, 0), tcp.advance_write_head(65_504, 32, 57, 65_536));
    try std.testing.expectEqual(@as(usize, 25), tcp.advance_write_head(10, 15, 20, 65_536));
}

test "tcp: suffix ring copy skips bytes a direct send accepted" {
    var buffer = [_]u8{0} ** 8;
    const tail = tcp.copy_parts_suffix_to_ring(&buffer, 6, &.{ "ab", "cde" }, 3);

    try std.testing.expectEqual(@as(usize, 0), tail);
    try std.testing.expectEqualStrings("de", buffer[6..8]);
}

test "tcp: empty-ring write takes the direct sendmsg path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    var ring: [256]u8 = undefined;
    var conn = tcp.TcpConnection{
        .socket = @import("xev").TCP.initFd(pair[0]),
        .io = std.testing.io,
        .write_queue = &ring,
    };

    const payload = "direct sendmsg payload";
    try conn.write_data(payload);

    // The fast path must leave the ring empty and arm no write completion;
    // a fallback would have queued every byte and started a write.
    try std.testing.expectEqual(@as(usize, 0), conn.write_len);
    try std.testing.expect(!conn.is_writing);

    var received: [payload.len]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const read = try std.posix.read(pair[1], received[received_len..]);
        if (read == 0) break;
        received_len += read;
    }
    try std.testing.expectEqualStrings(payload, received[0..received_len]);
}

test "tcp: file response keeps the body pump armed before the head write" {
    if (!zero_copy.kernel_send_supported) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "uWebZockets static body";
    var file = try tmp.dir.createFile(std.testing.io, "asset.bin", .{ .read = true, .truncate = true });
    var file_owned = true;
    defer if (file_owned) file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, payload, 0);

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
        &pair,
    ) != 0) {
        return error.SkipZigTest;
    }
    defer _ = std.posix.system.close(pair[1]);

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);

    var ring: [512]u8 = undefined;
    var conn = tcp.TcpConnection{
        .socket = @import("xev").TCP.initFd(pair[0]),
        .io = std.testing.io,
        .write_queue = &ring,
    };
    conn.loop = event_loop.get_xev_loop();

    try conn.begin_file_response("200 OK", "", "", file, 0, payload.len, false);
    file_owned = false;

    // The head must not take a direct-send path that bypasses the completion
    // which drives pump_file_body.
    try std.testing.expect(conn.file_body != null);
    try std.testing.expect(conn.is_writing);

    // This test drives only the file transfer, so do not arm a read after it.
    conn.dispatch_suspended = false;
    try event_loop.xev_loop.run(.until_done);

    var received: [1024]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const read = std.posix.read(pair[1], received[received_len..]) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (read == 0) break;
        received_len += read;
    }
    try std.testing.expect(
        std.mem.indexOf(u8, received[0..received_len], "HTTP/1.1 200 OK") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, received[0..received_len], payload) != null,
    );

    tcp.close_connection(&conn);
    try event_loop.xev_loop.run(.until_done);
}

test "tcp: write batch defers and flushes pipelined responses in order" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);

    var ring: [256]u8 = undefined;
    var conn = tcp.TcpConnection{
        .socket = @import("xev").TCP.initFd(pair[0]),
        .io = std.testing.io,
        .write_queue = &ring,
    };
    conn.loop = event_loop.get_xev_loop();

    conn.begin_write_batch();
    try conn.write_data("one");
    try conn.write_data("two");

    // Both responses sit in the ring and no completion was armed yet.
    try std.testing.expectEqual(@as(usize, 6), conn.write_len);
    try std.testing.expect(!conn.is_writing);
    try std.testing.expectEqualStrings("onetwo", ring[0..6]);

    conn.end_write_batch();
    if (conn.is_writing) {
        try event_loop.xev_loop.run(.until_done);
    }
    try std.testing.expectEqual(@as(usize, 0), conn.write_len);
    try std.testing.expect(!conn.is_writing);

    var received: [6]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const read = try std.posix.read(pair[1], received[received_len..]);
        if (read == 0) break;
        received_len += read;
    }
    try std.testing.expectEqualStrings("onetwo", received[0..received_len]);
}

test "tcp: direct batch flush settles websocket backpressure" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const Drain = struct {
        var calls: usize = 0;

        fn on_drain(_: *WebSocket) void {
            calls += 1;
        }
    };
    Drain.calls = 0;

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    var ring: [512]u8 = undefined;
    var conn = tcp.TcpConnection{
        .socket = @import("xev").TCP.initFd(pair[0]),
        .io = std.testing.io,
        .write_queue = &ring,
    };
    conn.ws = WebSocket{
        .conn = &conn,
        .initialized = true,
        .behavior = .{ .drain = Drain.on_drain },
    };

    const payload = [_]u8{'x'} ** 300;
    conn.begin_write_batch();
    try conn.write_data(&payload);
    try std.testing.expect(conn.was_backpressured);

    // The direct flush empties the ring without a write completion; the batch
    // boundary must still resume the paused producer.
    conn.end_write_batch();
    try std.testing.expect(!conn.was_backpressured);
    try std.testing.expectEqual(@as(usize, 1), Drain.calls);
}

test "tcp: write batch drains before a pipelined overflow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    var ring: [64]u8 = undefined;
    var conn = tcp.TcpConnection{
        .socket = @import("xev").TCP.initFd(pair[0]),
        .io = std.testing.io,
        .write_queue = &ring,
    };

    const first = [_]u8{'a'} ** 40;
    const second = [_]u8{'b'} ** 40;
    conn.begin_write_batch();
    try conn.write_data(&first);
    try conn.write_data(&second);

    // The second write could not fit beside the first, so the first 40 bytes
    // were flushed and only the second response remains queued.
    try std.testing.expectEqual(@as(usize, 40), conn.write_len);
    try std.testing.expectEqualStrings(&second, ring[0..40]);

    conn.end_write_batch();
    try std.testing.expectEqual(@as(usize, 0), conn.write_len);

    var received: [80]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const read = try std.posix.read(pair[1], received[received_len..]);
        if (read == 0) break;
        received_len += read;
    }
    try std.testing.expectEqualSlices(u8, &first, received[0..40]);
    try std.testing.expectEqualSlices(u8, &second, received[40..80]);
}

test "tcp: set_nodelay enables TCP_NODELAY on a socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const fd = std.c.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    tcp.set_nodelay(fd);

    var value: c_int = 0;
    var length: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        @ptrCast(&value),
        &length,
    );
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqual(@as(c_int, 1), value);
}

test "tcp: listener sets TCP_DEFER_ACCEPT" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const server = try tcp.init_server("127.0.0.1", 0, dummy_accept, null);
    defer tcp.close_socket(@import("xev").tcp_fd(server.listener));

    var value: c_int = 0;
    var length: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(
        @import("xev").tcp_fd(server.listener),
        std.posix.IPPROTO.TCP,
        std.os.linux.TCP.DEFER_ACCEPT,
        @ptrCast(&value),
        &length,
    );
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(value > 0);
}

test "tcp: request_quickack sets TCP_QUICKACK" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const fd = std.c.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    tcp.request_quickack(fd);

    var value: c_int = 0;
    var length: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.os.linux.TCP.QUICKACK,
        @ptrCast(&value),
        &length,
    );
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqual(@as(c_int, 1), value);
}

test "core: kernel sendfile streams a regular file into a socket" {
    if (!zero_copy.kernel_send_supported) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "uWebZockets zero-copy payload sent at the kernel boundary";
    var file = try tmp.dir.createFile(std.testing.io, "asset.bin", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, payload, 0);

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    var offset: u64 = 0;
    const sent = try zero_copy.send_file_chunk(pair[0], file.handle, &offset, payload.len);
    try std.testing.expectEqual(@as(usize, payload.len), sent);
    try std.testing.expectEqual(@as(u64, payload.len), offset);

    var received: [payload.len]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const read = try std.posix.read(pair[1], received[received_len..]);
        if (read == 0) break;
        received_len += read;
    }
    try std.testing.expectEqualStrings(payload, received[0..received_len]);
}

test "core: kernel sendfile defers instead of blocking a saturated socket" {
    if (!zero_copy.kernel_send_supported) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var payload: [64 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    var file = try tmp.dir.createFile(std.testing.io, "large.bin", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &payload, 0);

    var pair: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.posix.system.close(pair[0]);
        _ = std.posix.system.close(pair[1]);
    }

    // Shrink the send buffer, then fill it so the next kernel transfer has to
    // report EAGAIN instead of sleeping.
    std.posix.setsockopt(
        pair[0],
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        &std.mem.toBytes(@as(c_int, 4096)),
    ) catch {};
    const fill_window = zero_copy.open_nonblocking_window(pair[0]);
    try std.testing.expectEqual(zero_copy.NonblockingWindow.enabled, fill_window);
    var filler: [4096]u8 = @splat(0);
    while (std.c.write(pair[0], &filler, filler.len) >= 0) {}
    zero_copy.close_nonblocking_window(fill_window, pair[0]);

    const window = zero_copy.open_nonblocking_window(pair[0]);
    try std.testing.expectEqual(zero_copy.NonblockingWindow.enabled, window);
    var offset: u64 = 0;
    try std.testing.expectError(
        error.WouldBlock,
        zero_copy.send_file_chunk(pair[0], file.handle, &offset, payload.len),
    );
    try std.testing.expectEqual(@as(u64, 0), offset);
    zero_copy.close_nonblocking_window(window, pair[0]);

    // Draining the peer gives the kernel path room to make progress again.
    const drain_window = zero_copy.open_nonblocking_window(pair[1]);
    try std.testing.expectEqual(zero_copy.NonblockingWindow.enabled, drain_window);
    var drain: [4096]u8 = undefined;
    while (true) {
        _ = std.posix.read(pair[1], &drain) catch break;
    }
    zero_copy.close_nonblocking_window(drain_window, pair[1]);

    const resumed = zero_copy.open_nonblocking_window(pair[0]);
    try std.testing.expectEqual(zero_copy.NonblockingWindow.enabled, resumed);
    const sent = try zero_copy.send_file_chunk(pair[0], file.handle, &offset, payload.len);
    zero_copy.close_nonblocking_window(resumed, pair[0]);
    try std.testing.expect(sent != 0);
    try std.testing.expectEqual(@as(u64, sent), offset);
}

test "tcp: closed connection waits for active completions" {
    const Release = struct {
        var count: usize = 0;

        fn callback(_: *anyopaque, _: *tcp.TcpConnection) void {
            count += 1;
        }
    };

    var pool_token: u8 = 0;
    var conn = tcp.TcpConnection{
        .socket = undefined,
        .closing = true,
        .close_complete = true,
        .read_active = true,
        .is_writing = true,
        .pool_ptr = &pool_token,
        .on_close_cb = Release.callback,
    };

    Release.count = 0;
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.read_active = false;
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.is_writing = false;
    tcp.release_closed_connection(&conn);
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 1), Release.count);
}

test "tcp: server close drains an outstanding accept" {
    const Accept = struct {
        fn callback(socket: @import("xev").TCP, _: ?*anyopaque) void {
            tcp.close_socket(@import("xev").tcp_fd(socket));
        }
    };

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);
    var server = try tcp.init_server("127.0.0.1", 0, Accept.callback, null);

    tcp.accept_start(&server, &event_loop);
    tcp.close_server(&server, &event_loop);
    try loop.run(&event_loop);
    try std.testing.expect(server.close_complete);
}

test "timer: stop drains the active completion" {
    const Tick = struct {
        fn callback() void {}
    };

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);
    var active_timer = try timer.init_timer(60_000, Tick.callback);
    defer timer.deinit_timer(&active_timer);

    timer.start_timer(&active_timer, &event_loop);
    timer.stop_timer(&active_timer, &event_loop);
    try loop.run(&event_loop);
    try std.testing.expect(!active_timer.active);
}

test "timer: stop from inside the tick callback terminates the timer" {
    const Stop = struct {
        var timer_context: ?*timer.TimerContext = null;
        var loop_ptr: ?*loop.Loop = null;
        var ticks: usize = 0;

        fn tick() void {
            ticks += 1;
            timer.stop_timer(timer_context.?, loop_ptr.?);
        }
    };

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);
    var stopping_timer = try timer.init_timer(1, Stop.tick);
    defer timer.deinit_timer(&stopping_timer);
    Stop.timer_context = &stopping_timer;
    Stop.loop_ptr = &event_loop;
    Stop.ticks = 0;

    timer.start_timer(&stopping_timer, &event_loop);
    // The callback stops the timer, so an until_done run must return after
    // exactly one tick; a re-arm would hang this test instead of failing it.
    try event_loop.xev_loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), Stop.ticks);
    try std.testing.expect(!stopping_timer.active);
    try std.testing.expect(stopping_timer.stopping);
}
