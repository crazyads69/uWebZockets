//! Streams-inspired byte primitives.
//!
//! Provides zero-allocation readable and writable byte-stream abstractions
//! with Bring-Your-Own-Buffer (BYOB) reading, chunk writing, and backpressure control.

/// Stream state reflecting the local adapter lifecycle.
pub const StreamState = enum(u8) {
    readable,
    closed,
    errored,
};

/// Reads up to `dest.len` bytes into caller storage and returns the count.
pub const ReadableReadFn = *const fn (context: *anyopaque, dest: []u8) anyerror!usize;
/// Releases the reader context; non-failing, best-effort teardown.
pub const ReadableCloseFn = *const fn (context: *anyopaque) void;

/// Writes one chunk without retaining it.
pub const WritableWriteFn = *const fn (context: *anyopaque, chunk: []const u8) anyerror!void;
/// Finalizes the writable stream context.
pub const WritableCloseFn = *const fn (context: *anyopaque) anyerror!void;
/// Reports whether the transport currently asserts write backpressure.
pub const WritableBackpressureFn = *const fn (context: *anyopaque) bool;

/// Zero-allocation readable byte stream with BYOB ("Bring Your Own Buffer") reader.
///
/// Implements a pull-based byte-oriented reader pattern.
pub const ReadableByteStream = struct {
    context: *anyopaque,
    read_fn: ReadableReadFn,
    close_fn: ?ReadableCloseFn = null,
    state: StreamState = .readable,

    /// Reads up to `dest.len` bytes into the caller-owned buffer (BYOB reading).
    ///
    /// Returns 0 when EOF is reached.
    pub fn read(self: *ReadableByteStream, dest: []u8) !usize {
        if (self.state != .readable) return 0;
        if (dest.len == 0) return 0;

        const bytes_read = self.read_fn(self.context, dest) catch |err| {
            self.state = .errored;
            return err;
        };
        if (bytes_read > dest.len) {
            self.state = .errored;
            return error.InvalidReadCount;
        }
        if (bytes_read == 0) {
            self.state = .closed;
        }
        return bytes_read;
    }

    /// Closes the readable stream and invalidates further reads.
    pub fn cancel(self: *ReadableByteStream) void {
        if (self.state == .closed) return;
        self.state = .closed;
        if (self.close_fn) |close_cb| close_cb(self.context);
    }

    /// Reports whether the stream has finished or errored.
    pub fn is_closed(self: *const ReadableByteStream) bool {
        return self.state != .readable;
    }
};

/// Result of one WHATWG BYOB reader operation.
pub const ReadResult = struct {
    value: []u8,
    done: bool,
};

/// Exclusive BYOB reader borrowing a ReadableByteStream.
pub const ReadableStreamBYOBReader = struct {
    stream: *ReadableByteStream,
    released: bool = false,

    pub fn read(self: *ReadableStreamBYOBReader, view: []u8) !ReadResult {
        if (self.released) return error.ReaderReleased;
        const count = try self.stream.read(view);
        return .{
            .value = view[0..count],
            .done = count == 0 and self.stream.is_closed(),
        };
    }

    pub fn cancel(self: *ReadableStreamBYOBReader) void {
        if (self.released) return;
        self.stream.cancel();
        self.released = true;
    }

    pub fn release_lock(self: *ReadableStreamBYOBReader) void {
        self.released = true;
    }
};

/// Acquires a BYOB reader without allocating controller state.
pub fn get_byob_reader(stream: *ReadableByteStream) ReadableStreamBYOBReader {
    return .{ .stream = stream };
}

/// Slice-backed readable stream reader context for fixed in-memory bodies.
pub const SliceReaderContext = struct {
    data: []const u8,
    cursor: usize = 0,

    pub fn read(context: *anyopaque, dest: []u8) anyerror!usize {
        const self: *SliceReaderContext = @ptrCast(@alignCast(context));
        if (self.cursor >= self.data.len) return 0;
        const available = self.data.len - self.cursor;
        const count = @min(dest.len, available);
        @memcpy(dest[0..count], self.data[self.cursor .. self.cursor + count]);
        self.cursor += count;
        return count;
    }
};

/// Zero-allocation writable byte stream.
///
/// Provides bounded chunk writes, end-of-stream signaling, and backpressure awareness.
pub const WritableByteStream = struct {
    context: *anyopaque,
    write_fn: WritableWriteFn,
    close_fn: WritableCloseFn,
    is_backpressured_fn: ?WritableBackpressureFn = null,
    state: StreamState = .readable,

    /// Writes one chunk to the destination transport.
    pub fn write(self: *WritableByteStream, chunk: []const u8) !void {
        if (self.state != .readable) return error.StreamClosed;
        if (chunk.len == 0) return;

        self.write_fn(self.context, chunk) catch |err| {
            self.state = .errored;
            return err;
        };
    }

    /// Finalizes the stream and closes the underlying transport side.
    pub fn close(self: *WritableByteStream) !void {
        if (self.state == .closed) return;
        self.state = .closed;
        try self.close_fn(self.context);
    }

    /// Reports whether write backpressure is currently asserted by the transport.
    pub fn is_backpressured(self: *const WritableByteStream) bool {
        const check_fn = self.is_backpressured_fn orelse return false;
        return check_fn(self.context);
    }
};

/// Pipes data from a ReadableByteStream to a WritableByteStream using a caller-owned transfer buffer.
///
/// Zero dynamic allocations are performed.
pub fn pipe_to(
    reader: *ReadableByteStream,
    writer: *WritableByteStream,
    buffer: []u8,
) !usize {
    if (buffer.len == 0) return error.EmptyTransferBuffer;
    errdefer {
        reader.cancel();
        // Best effort: the caller receives the original transfer error; a
        // close failure cannot change it.
        writer.close() catch {};
    }

    var total_bytes: usize = 0;
    while (!reader.is_closed()) {
        const read_count = try reader.read(buffer);
        if (read_count == 0) break;
        try writer.write(buffer[0..read_count]);
        total_bytes += read_count;
    }
    try writer.close();
    return total_bytes;
}
