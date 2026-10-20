const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const invalid_socket: std.posix.socket_t = if (builtin.os.tag == .windows)
    @ptrFromInt(std.math.maxInt(usize))
else
    -1;

pub fn is_valid_socket(fd: std.posix.socket_t) bool {
    return if (builtin.os.tag == .windows)
        @intFromPtr(fd) != std.math.maxInt(usize)
    else
        fd >= 0;
}

/// Reports that the build includes the lsquic support layer.
pub const available = true;
/// Maximum UDP payload accepted by the packet adapter.
pub const max_udp_payload_size: usize = 2048;

var global_lock: std.atomic.Mutex = .unlocked;
var global_references: usize = 0;

/// Acquires one process-wide lsquic server initialization reference.
pub fn acquire_global() !void {
    lock_global();
    defer global_lock.unlock();

    if (global_references == 0) {
        if (c.lsquic_global_init(c.LSQUIC_GLOBAL_SERVER) != 0) {
            return error.LsquicGlobalInitFailed;
        }
    }
    if (global_references == std.math.maxInt(usize)) {
        return error.ReferenceCountOverflow;
    }
    global_references += 1;
}

/// Releases one initialization reference and cleans up at zero references.
pub fn release_global() void {
    lock_global();
    defer global_lock.unlock();

    std.debug.assert(global_references != 0);
    global_references -= 1;
    if (global_references == 0) c.lsquic_global_cleanup();
}

fn lock_global() void {
    while (!global_lock.tryLock()) std.atomic.spinLoopHint();
}

/// Inline native socket-address storage accepted by lsquic.
pub const Sockaddr = struct {
    storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage),
    length: c.socklen_t = 0,

    /// Encodes an IPv4 or IPv6 address into native socket storage.
    pub fn init(address: std.Io.net.IpAddress) Sockaddr {
        var result = Sockaddr{};

        switch (address) {
            .ip4 => |value| {
                const sockaddr: *std.posix.sockaddr.in = @ptrCast(@alignCast(&result.storage));
                sockaddr.* = std.mem.zeroes(std.posix.sockaddr.in);
                sockaddr.family = std.posix.AF.INET;
                sockaddr.port = std.mem.nativeToBig(u16, value.port);
                sockaddr.addr = @bitCast(value.bytes);
                result.length = @sizeOf(std.posix.sockaddr.in);
            },
            .ip6 => |value| {
                const sockaddr: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&result.storage));
                sockaddr.* = std.mem.zeroes(std.posix.sockaddr.in6);
                sockaddr.family = std.posix.AF.INET6;
                sockaddr.port = std.mem.nativeToBig(u16, value.port);
                sockaddr.addr = value.bytes;
                result.length = @sizeOf(std.posix.sockaddr.in6);
            },
        }
        return result;
    }

    /// Returns a borrowed C socket-address pointer valid while `self` lives.
    pub fn ptr(self: *const Sockaddr) [*c]const c.struct_sockaddr {
        return @ptrCast(&self.storage);
    }
};

/// Sends a batch of lsquic packet specifications on a non-blocking UDP socket.
///
/// Returns the number sent, or -1 with `errno` set when no packet was sent.
pub fn send_packets(
    fd: std.posix.socket_t,
    specs: [*c]const c.lsquic_out_spec,
    count: c_uint,
) c_int {
    if (!is_valid_socket(fd)) return fail_with_errno(.BADF);
    if (specs == null) return fail_with_errno(.INVAL);
    if (count == 0) return 0;

    const packet_count: usize = @intCast(count);
    if (builtin.os.tag == .linux) {
        if (send_segmented(fd, specs, packet_count)) |segments| {
            if (segments == 0) return -1;
            return @intCast(segments);
        }
    }
    var sent: usize = 0;
    packet_loop: while (sent < packet_count) : (sent += 1) {
        const spec = specs[sent];
        if (spec.dest_sa == null or spec.iov == null or spec.iovlen == 0) {
            set_errno(.INVAL);
            break;
        }

        var total_size: usize = 0;
        var index: usize = 0;
        while (index < spec.iovlen) : (index += 1) {
            const part_size = spec.iov[index].iov_len;
            if (part_size > max_udp_payload_size -| total_size) break;
            total_size += part_size;
        }
        if (index != spec.iovlen or total_size == 0) {
            set_errno(.MSGSIZE);
            break;
        }

        const address_length: c.socklen_t = switch (spec.dest_sa.*.sa_family) {
            c.AF_INET => @sizeOf(std.posix.sockaddr.in),
            c.AF_INET6 => @sizeOf(std.posix.sockaddr.in6),
            else => {
                set_errno(.AFNOSUPPORT);
                break :packet_loop;
            },
        };
        if (builtin.os.tag == .windows) {
            var wsa_bufs: [32]c.WSABUF = undefined;
            if (spec.iovlen > wsa_bufs.len) {
                set_errno(.INVAL);
                break;
            }
            var i: usize = 0;
            while (i < spec.iovlen) : (i += 1) {
                wsa_bufs[i] = .{
                    .len = @intCast(spec.iov[i].iov_len),
                    .buf = @ptrCast(spec.iov[i].iov_base),
                };
            }
            var bytes_sent: c.DWORD = 0;
            const sock: c.SOCKET = @intCast(@intFromPtr(fd));
            const rc = c.WSASendTo(
                sock,
                &wsa_bufs,
                @intCast(spec.iovlen),
                &bytes_sent,
                0,
                @ptrCast(spec.dest_sa),
                @intCast(address_length),
                null,
                null,
            );
            if (rc != 0) {
                set_errno(winsock_errno(c.WSAGetLastError()));
                break;
            }
            if (bytes_sent != total_size) {
                set_errno(.IO);
                break;
            }
        } else {
            var message = c.struct_msghdr{
                .msg_name = @ptrCast(@constCast(spec.dest_sa)),
                .msg_namelen = address_length,
                .msg_iov = spec.iov,
                .msg_iovlen = @intCast(spec.iovlen),
            };
            const written = c.sendmsg(fd, &message, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
            if (written < 0) break;
            if (@as(usize, @intCast(written)) != total_size) {
                set_errno(.IO);
                break;
            }
        }
    }

    if (sent == 0) return -1;
    return @intCast(sent);
}

/// Maximum packets coalesced into one Linux UDP GSO send.
const gso_max_segments = 64;
const udp_segment_option: c_int = 103;

/// Sends an equal-sized same-destination batch with one UDP_SEGMENT sendmsg.
///
/// Returns the segment count when the kernel accepted the batch, null when the
/// batch is not eligible or the send failed before bytes were transmitted, and
/// zero when a partial send left no complete segment.
fn send_segmented(
    fd: std.posix.socket_t,
    specs: [*c]const c.lsquic_out_spec,
    packet_count: usize,
) ?usize {
    if (packet_count < 2 or packet_count > gso_max_segments) return null;
    const first = specs[0];
    if (first.dest_sa == null or first.iov == null or first.iovlen == 0) return null;

    const address_length: c.socklen_t = switch (first.dest_sa.*.sa_family) {
        c.AF_INET => @sizeOf(std.posix.sockaddr.in),
        c.AF_INET6 => @sizeOf(std.posix.sockaddr.in6),
        else => return null,
    };
    const first_address = @as([*]const u8, @ptrCast(first.dest_sa))[0..address_length];

    var segment_size: usize = 0;
    for (first.iov[0..first.iovlen]) |part| {
        if (part.iov_len > max_udp_payload_size -| segment_size) return null;
        segment_size += part.iov_len;
    }
    if (segment_size == 0 or segment_size > std.math.maxInt(u16)) return null;

    var iovecs: [gso_max_segments]c.struct_iovec = undefined;
    var iov_count: usize = 0;
    for (0..packet_count) |packet_index| {
        const spec = specs[packet_index];
        if (spec.dest_sa == null or spec.iov == null or spec.iovlen == 0) return null;
        if (spec.ecn != 0) return null;
        if (spec.dest_sa.*.sa_family != first.dest_sa.*.sa_family) return null;
        const address = @as([*]const u8, @ptrCast(spec.dest_sa))[0..address_length];
        if (!std.mem.eql(u8, first_address, address)) return null;

        var packet_size: usize = 0;
        for (spec.iov[0..spec.iovlen]) |part| {
            if (part.iov_len > max_udp_payload_size -| packet_size) return null;
            packet_size += part.iov_len;
            if (iov_count == iovecs.len) return null;
            iovecs[iov_count] = .{
                .iov_base = part.iov_base,
                .iov_len = part.iov_len,
            };
            iov_count += 1;
        }
        if (packet_size != segment_size) return null;
    }

    const cmsg_data_offset = comptime std.mem.alignForward(
        usize,
        @sizeOf(c.struct_cmsghdr),
        @alignOf(usize),
    );
    const cmsg_len = comptime cmsg_data_offset + @sizeOf(u16);
    var control: [cmsg_len]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    const cmsg: *c.struct_cmsghdr = @ptrCast(&control);
    cmsg.* = std.mem.zeroes(c.struct_cmsghdr);
    cmsg.cmsg_len = @intCast(cmsg_len);
    cmsg.cmsg_level = c.IPPROTO_UDP;
    cmsg.cmsg_type = udp_segment_option;
    const segment_value: *u16 = @ptrCast(@alignCast(&control[cmsg_data_offset]));
    segment_value.* = @intCast(segment_size);

    var message = c.struct_msghdr{
        .msg_name = @ptrCast(@constCast(first.dest_sa)),
        .msg_namelen = address_length,
        .msg_iov = &iovecs,
        .msg_iovlen = @intCast(iov_count),
        .msg_control = &control,
        .msg_controllen = cmsg.cmsg_len,
    };
    const written = c.sendmsg(fd, &message, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
    if (written < 0) return null;

    const total_size = segment_size * packet_count;
    if (@as(usize, @intCast(written)) > total_size) return null;
    const segments = @divTrunc(@as(usize, @intCast(written)), segment_size);
    if (segments == 0) {
        set_errno(.AGAIN);
        return 0;
    }
    return segments;
}

fn winsock_errno(wsa_error: c_int) std.c.E {
    if (builtin.os.tag != .windows) unreachable;
    return switch (wsa_error) {
        c.WSAEWOULDBLOCK, c.WSAENOBUFS => .AGAIN,
        c.WSAEINTR => .INTR,
        c.WSAEMSGSIZE => .MSGSIZE,
        c.WSAEAFNOSUPPORT => .AFNOSUPPORT,
        c.WSAEINVAL => .INVAL,
        c.WSAEBADF, c.WSAENOTSOCK => .BADF,
        else => .IO,
    };
}

fn fail_with_errno(err: std.c.E) c_int {
    set_errno(err);
    return -1;
}

fn set_errno(err: std.c.E) void {
    std.c._errno().* = @intFromEnum(err);
}
