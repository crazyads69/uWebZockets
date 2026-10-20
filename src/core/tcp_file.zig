const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const tcp = @import("tcp.zig");
const TcpConnection = tcp.TcpConnection;
const zero_copy = @import("zero_copy.zig");

/// Largest part count the direct `sendmsg` fast path accepts as iovecs.
const direct_iovec_capacity = 8;

pub fn enqueue_plain_parts(conn: *TcpConnection, parts: []const []const u8) !void {
    if (conn.closing) return error.ConnectionClosed;

    var total_len: usize = 0;
    for (parts) |part| {
        if (part.len > conn.write_queue.len - total_len) return error.WouldBlock;
        total_len += part.len;
    }
    if (total_len == 0) return;

    // A pipelined batch can exceed the ring even when every individual
    // response fits. Drain the accumulated batch with one direct write before
    // rejecting the next response, so response amplification cannot turn a
    // valid pipeline into a mid-stream disconnect.
    if (conn.write_batch_depth != 0 and total_len > conn.write_queue.len - conn.write_len) {
        flush_batched(conn);
        if (conn.closing) return error.ConnectionClosed;
    }
    if (total_len > conn.write_queue.len - conn.write_len) return error.WouldBlock;

    if (comptime builtin.os.tag == .linux) {
        if (conn.write_batch_depth == 0 and try_direct_send(conn, parts, total_len)) return;
    }

    const tail = (conn.write_head + conn.write_len) % conn.write_queue.len;
    _ = tcp.copy_parts_to_ring(conn.write_queue, tail, parts);

    conn.write_len += total_len;
    if (conn.write_len >= conn.write_queue.len / 2) conn.was_backpressured = true;
    if (conn.write_batch_depth == 0) conn.start_write();
}

/// Sends the parts with one nonblocking `sendmsg` while the ring is empty.
///
/// Returns true when the caller must not queue anything else: either every byte
/// reached the kernel, or the unsent suffix was queued and the write completion
/// was armed. Returns false when the ordinary ring copy must run instead, which
/// also covers a send error and a partial send of zero bytes.
fn try_direct_send(conn: *TcpConnection, parts: []const []const u8, total_len: usize) bool {
    if (conn.ssl != null or conn.file_body != null) return false;
    if (conn.closing or conn.close_when_drained) return false;
    if (conn.write_len != 0 or conn.is_writing) return false;
    if (parts.len == 0 or parts.len > direct_iovec_capacity) return false;

    var iovecs: [direct_iovec_capacity]std.posix.iovec_const = undefined;
    for (parts, 0..) |part, index| {
        iovecs[index] = .{ .base = part.ptr, .len = part.len };
    }
    const message: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = parts.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    // DONTWAIT keeps a blocking io_uring socket from sleeping inside the event
    // loop; NOSIGNAL turns a peer reset into an error instead of SIGPIPE.
    const result = std.os.linux.sendmsg(
        xev.tcp_fd(conn.socket),
        &message,
        std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL,
    );
    if (std.os.linux.errno(result) != .SUCCESS) return false;

    const written = result;
    if (written == 0 or written > total_len) return false;

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    if (written == total_len) return true;

    const tail = (conn.write_head + conn.write_len) % conn.write_queue.len;
    _ = tcp.copy_parts_suffix_to_ring(conn.write_queue, tail, parts, written);
    conn.write_len = total_len - written;
    if (conn.write_len >= conn.write_queue.len / 2) conn.was_backpressured = true;
    conn.start_write();
    return true;
}

/// Flushes a completed write batch with one vectorized syscall when possible.
///
/// The ring contains plaintext or encrypted bytes depending on the transport;
/// both are safe to hand to one nonblocking `sendmsg`. The fallback arms the
/// ordinary completion even when a batch is still open.
pub fn flush_batched(conn: *TcpConnection) void {
    if (comptime builtin.os.tag == .linux) {
        if (try_direct_flush(conn)) return;
    }
    conn.arm_write();
}

fn try_direct_flush(conn: *TcpConnection) bool {
    if (conn.file_body != null) return false;
    // A producer expects the write completion to pull its next chunk.
    if (conn.stream_producer != null) return false;
    if (conn.closing or conn.is_writing or conn.write_len == 0) return false;

    const head = conn.write_head;
    const first_len = @min(conn.write_len, conn.write_queue.len - head);
    var iovecs: [2]std.posix.iovec_const = undefined;
    iovecs[0] = .{ .base = conn.write_queue[head..].ptr, .len = first_len };
    var part_count: usize = 1;
    if (conn.write_len > first_len) {
        iovecs[1] = .{ .base = conn.write_queue.ptr, .len = conn.write_len - first_len };
        part_count = 2;
    }

    const message: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = part_count,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const result = std.os.linux.sendmsg(
        xev.tcp_fd(conn.socket),
        &message,
        std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL,
    );
    if (std.os.linux.errno(result) != .SUCCESS) return false;

    const written = result;
    if (written == 0 or written > conn.write_len) return false;

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    conn.write_len -= written;
    conn.write_head = tcp.advance_write_head(
        conn.write_head,
        written,
        conn.write_len,
        conn.write_queue.len,
    );
    if (conn.write_len != 0) return false;
    if (conn.close_when_drained) tcp.close_connection(conn);
    return true;
}

/// Copies scatter/gather plaintext parts atomically into the write path.
pub fn write_data_parts(conn: *TcpConnection, parts: []const []const u8) !void {
    if (conn.closing or conn.close_when_drained) return error.ConnectionClosed;
    if (conn.ssl != null) return conn.write_tls_parts(parts);
    return enqueue_plain_parts(conn, parts);
}

fn finish_file_body(conn: *TcpConnection) void {
    const file = conn.file_body orelse return;
    conn.file_body = null;
    conn.file_remaining = 0;
    file.close(conn.io);

    if (conn.file_close_after) {
        conn.file_close_after = false;
        conn.dispatch_suspended = false;
        tcp.close_after_flush(conn);
        return;
    }
    if (conn.dispatch_suspended) conn.resume_async_dispatch();
}

/// Pushes queued plaintext, then streams the file until the socket stalls.
///
/// The kernel path needs a nonblocking socket: a blocking `sendfile` sleeps
/// until its full count is transferred. io_uring sockets are blocking, so
/// the transfer opens a temporary nonblocking window and closes it before
/// any completion is queued. A tick transfers at most `file_tick_budget`
/// bytes so one large asset cannot starve the worker.
pub fn pump_file_body(conn: *TcpConnection) void {
    if (comptime !zero_copy.kernel_send_supported) return;
    const file = conn.file_body orelse return;
    if (conn.closing or conn.is_writing or conn.write_len != 0) return;

    const window = zero_copy.open_nonblocking_window(xev.tcp_fd(conn.socket));
    if (window == .failed) {
        dribble_file_body(conn, file);
        return;
    }

    var budget = tcp.file_tick_budget;
    while (conn.file_remaining != 0 and budget != 0) {
        const chunk: usize = @intCast(@min(
            @min(conn.file_remaining, zero_copy.max_chunk),
            budget,
        ));
        const sent = zero_copy.send_file_chunk(
            xev.tcp_fd(conn.socket),
            file.handle,
            &conn.file_offset,
            chunk,
        ) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                zero_copy.close_nonblocking_window(window, xev.tcp_fd(conn.socket));
                tcp.close_connection(conn);
                return;
            },
        };
        // A short read below Content-Length would desynchronize framing.
        if (sent == 0) {
            zero_copy.close_nonblocking_window(window, xev.tcp_fd(conn.socket));
            tcp.close_connection(conn);
            return;
        }
        conn.file_remaining -= sent;
        budget -= sent;
    }
    zero_copy.close_nonblocking_window(window, xev.tcp_fd(conn.socket));

    if (conn.closing) return;
    if (conn.file_remaining == 0) {
        finish_file_body(conn);
        return;
    }
    dribble_file_body(conn, file);
}

/// Bounded copy fallback used while the kernel path cannot proceed.
///
/// Reuses the TLS staging buffer because a plaintext connection never
/// touches it, keeping the per-connection footprint unchanged.
fn dribble_file_body(conn: *TcpConnection, file: std.Io.File) void {
    const available = conn.write_queue.len - conn.write_len;
    if (available == 0) return;

    const wanted: usize = @intCast(@min(
        @min(conn.file_remaining, available),
        conn.tls_write_buffer.len,
    ));
    if (wanted == 0) return;

    const read = file.readPositionalAll(
        conn.io,
        conn.tls_write_buffer[0..wanted],
        conn.file_offset,
    ) catch {
        tcp.close_connection(conn);
        return;
    };
    if (read == 0) {
        tcp.close_connection(conn);
        return;
    }
    enqueue_plain_parts(conn, &.{conn.tls_write_buffer[0..read]}) catch {
        tcp.close_connection(conn);
        return;
    };
    conn.file_offset += read;
    conn.file_remaining -= read;
    if (conn.file_remaining == 0) finish_file_body(conn);
}
