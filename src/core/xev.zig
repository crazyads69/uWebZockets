//! Runtime-selectable libxev API for the transport layer.
//!
//! libxev is imported through this module so a Linux build can fall back from
//! io_uring to epoll when the kernel or a container seccomp policy rejects
//! io_uring. Targets with a single backend re-export libxev's static API, so
//! no runtime dispatch is added there.
//!
//! `detect` must run before the first loop or watcher is created; the build
//! graph imports this module as `xev`, keeping transport code backend-neutral.

const std = @import("std");
const impl = @import("xev_impl");
const api = impl.Dynamic;

/// True when more than one backend can be selected at runtime.
pub const dynamic = api.dynamic;

/// Active backend type: a subset on dynamic targets, the concrete enum on
/// single-backend targets.
pub const Backend = if (api.dynamic) api.Backend else @TypeOf(api.backend);

pub const Loop = api.Loop;
pub const Completion = api.Completion;
pub const CallbackAction = api.CallbackAction;
pub const ReadBuffer = api.ReadBuffer;
pub const WriteBuffer = api.WriteBuffer;
// The static single-backend API does not forward the thread pool; libxev's
// package root exports it for every target.
pub const ThreadPool = impl.ThreadPool;
pub const RunMode = api.RunMode;
pub const Async = api.Async;
pub const File = api.File;
pub const Timer = api.Timer;
pub const TCP = api.TCP;
pub const UDP = api.UDP;
pub const AcceptError = api.AcceptError;
pub const CancelError = api.CancelError;
pub const CloseError = api.CloseError;
pub const ConnectError = api.ConnectError;
pub const PollError = api.PollError;
pub const PollEvent = api.PollEvent;
pub const ReadError = api.ReadError;
pub const ShutdownError = api.ShutdownError;
pub const WriteError = api.WriteError;

/// Native descriptor type behind TCP and UDP watchers.
pub const SocketFd = if (@import("builtin").os.tag == .windows)
    std.os.windows.HANDLE
else
    std.posix.fd_t;

/// Cancellation callback accepted by `cancel`.
pub fn cancel_callback(comptime Userdata: type) type {
    return *const fn (
        userdata: ?*Userdata,
        loop: *Loop,
        completion: *Completion,
        result: CancelError!void,
    ) CallbackAction;
}

/// Returns the backend selected by `detect`.
pub inline fn backend() Backend {
    return api.backend;
}

/// Reports whether the active backend is kqueue.
pub inline fn is_kqueue() bool {
    return std.mem.eql(u8, @tagName(api.backend), "kqueue");
}

/// Reports whether canceling an armed fd completion abandons that completion's
/// callback. epoll removes the registration without invoking it; the close
/// callback must clear the flags such a completion would otherwise clear.
/// kqueue and io_uring deliver a Canceled callback once the target is active.
pub inline fn cancel_abandons_target() bool {
    return std.mem.eql(u8, @tagName(api.backend), "epoll");
}

/// Reports whether a close path must flush queued completions before canceling.
///
/// kqueue drops the callback of a completion canceled while it is still in the
/// submission queue. Submitting first makes the target active so its Canceled
/// callback can clear the target flag and keep the slot out of the free list.
pub inline fn submit_before_cancel() bool {
    return is_kqueue();
}

/// Returns the descriptor behind a TCP watcher.
pub inline fn tcp_fd(socket: TCP) SocketFd {
    if (comptime api.dynamic) return socket.fd();
    return socket.fd;
}

/// Returns the descriptor behind a UDP watcher.
pub inline fn udp_fd(socket: UDP) SocketFd {
    if (comptime api.dynamic) return socket.fd();
    return socket.fd;
}

/// Selects the first available backend. Repeated calls are harmless.
pub fn detect() error{NoAvailableBackends}!void {
    if (comptime api.dynamic) try api.detect();
}

/// Requests `be` when it is available on this target.
pub fn prefer(be: Backend) bool {
    if (comptime api.dynamic) return api.prefer(@enumFromInt(@intFromEnum(be)));
    return be == api.backend;
}

/// Submits completions that the backend queued but has not started yet.
///
/// IOCP and kqueue defer queued operations until the next submit. A close from
/// the callback that queued its read or write must submit before canceling, or
/// the cancel only marks the target dead and its callback never fires. epoll
/// and io_uring start operations during `add`.
pub fn submit(loop: *Loop) !void {
    if (comptime api.dynamic) {
        switch (api.backend) {
            inline else => |tag| {
                const BackendApi = (comptime api.superset(tag)).Api();
                if (comptime @hasDecl(BackendApi.Loop, "submit")) {
                    const inner: *BackendApi.Loop = &@field(loop.backend, @tagName(tag));
                    try inner.submit();
                }
            },
        }
        return;
    }

    if (comptime @hasDecl(Loop, "submit")) try loop.submit();
}

/// Cancels `completion` and reports the outcome through `callback`.
///
/// kqueue reconciles its active count through `process_cancellations` and
/// delivers the target callback after the submission queue is flushed. The
/// close path therefore waits for both the target and cancel callbacks.
pub fn cancel(
    loop: *Loop,
    completion: *Completion,
    cancel_completion: *Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime callback: cancel_callback(Userdata),
) void {
    if (comptime api.dynamic) {
        cancel_dynamic(loop, completion, cancel_completion, Userdata, userdata, callback);
    } else {
        cancel_static(loop, completion, cancel_completion, Userdata, userdata, callback);
    }
}

fn cancel_static(
    loop: *Loop,
    completion: *Completion,
    cancel_completion: *Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime callback: cancel_callback(Userdata),
) void {
    if (api.backend == .io_uring) {
        loop.cancel(completion, cancel_completion, Userdata, userdata, struct {
            fn on_result(
                raw_userdata: ?*anyopaque,
                inner_loop: *Loop,
                inner_completion: *Completion,
                result: api.Result,
            ) CallbackAction {
                return @call(.always_inline, callback, .{
                    userdata_from_raw(Userdata, raw_userdata),
                    inner_loop,
                    inner_completion,
                    if (result.cancel) |_| {} else |err| err,
                });
            }
        }.on_result);
        return;
    }

    cancel_completion.* = .{
        .op = .{ .cancel = .{ .c = completion } },
        .userdata = userdata,
        .callback = struct {
            fn on_result(
                raw_userdata: ?*anyopaque,
                inner_loop: *Loop,
                inner_completion: *Completion,
                result: api.Result,
            ) CallbackAction {
                return @call(.always_inline, callback, .{
                    userdata_from_raw(Userdata, raw_userdata),
                    inner_loop,
                    inner_completion,
                    if (result.cancel) |_| {} else |err| err,
                });
            }
        }.on_result,
    };
    loop.add(cancel_completion);
}

fn cancel_dynamic(
    loop: *Loop,
    completion: *Completion,
    cancel_completion: *Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime callback: cancel_callback(Userdata),
) void {
    switch (api.backend) {
        inline else => |tag| {
            const BackendApi = (comptime api.superset(tag)).Api();
            const inner_loop: *BackendApi.Loop = &@field(loop.backend, @tagName(tag));
            completion.ensureTag(tag);
            cancel_completion.ensureTag(tag);
            const inner_completion: *BackendApi.Completion = &@field(completion.value, @tagName(tag));
            const inner_cancel: *BackendApi.Completion = &@field(cancel_completion.value, @tagName(tag));
            // A cancel op is portable across the dynamic candidates; the
            // io_uring helper does exactly this internally.
            inner_cancel.* = .{
                .op = .{ .cancel = .{ .c = inner_completion } },
                .userdata = userdata,
                .callback = struct {
                    fn on_result(
                        raw_userdata: ?*anyopaque,
                        raw_loop: *BackendApi.Loop,
                        raw_completion: *BackendApi.Completion,
                        result: BackendApi.Result,
                    ) BackendApi.CallbackAction {
                        const typed_loop: *Loop = @fieldParentPtr(
                            "backend",
                            @as(*Loop.Union, @fieldParentPtr(@tagName(tag), raw_loop)),
                        );
                        const typed_completion: *Completion = @fieldParentPtr(
                            "value",
                            @as(*Completion.Union, @fieldParentPtr(@tagName(tag), raw_completion)),
                        );
                        return @call(.always_inline, callback, .{
                            userdata_from_raw(Userdata, raw_userdata),
                            typed_loop,
                            typed_completion,
                            if (result.cancel) |_| {} else |err| err,
                        });
                    }
                }.on_result,
            };
            inner_loop.add(inner_cancel);
        },
    }
}

inline fn userdata_from_raw(comptime Userdata: type, raw: ?*anyopaque) ?*Userdata {
    if (Userdata == void) return null;
    return @ptrCast(@alignCast(raw));
}
