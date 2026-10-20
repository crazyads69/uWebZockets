const std = @import("std");
const c = @import("c");

/// Reusable per-worker gzip codec and bounded output scratch.
///
/// `init` runs during application startup. Every later `gzip` call uses the
/// caller-owned scratch and never allocates, so response paths stay bounded.
pub const Pool = struct {
    compressor: *c.libdeflate_compressor,
    scratch: []u8,
    max_input: usize,

    pub const Error = error{
        InitFailed,
        OutOfMemory,
        InputTooLarge,
        BufferTooSmall,
    };

    /// Allocates one codec and the worst-case gzip bound for `max_input`.
    pub fn init(max_input: usize) Error!Pool {
        if (max_input == 0) return error.InputTooLarge;
        const compressor = c.libdeflate_alloc_compressor(6) orelse
            return error.InitFailed;
        errdefer c.libdeflate_free_compressor(compressor);

        const bound = c.libdeflate_gzip_compress_bound(compressor, max_input);
        if (bound == 0) return error.InputTooLarge;
        const scratch = std.heap.page_allocator.alloc(u8, bound) catch
            return error.OutOfMemory;
        return .{
            .compressor = compressor,
            .scratch = scratch,
            .max_input = max_input,
        };
    }

    pub fn deinit(self: *Pool) void {
        std.heap.page_allocator.free(self.scratch);
        c.libdeflate_free_compressor(self.compressor);
        self.* = undefined;
    }

    /// Compresses one body into the pool scratch.
    ///
    /// The returned slice is valid until the next `gzip` or `deinit` call.
    pub fn gzip(self: *Pool, input: []const u8) Error![]const u8 {
        if (input.len > self.max_input) return error.InputTooLarge;
        const written = c.libdeflate_gzip_compress(
            self.compressor,
            input.ptr,
            input.len,
            self.scratch.ptr,
            self.scratch.len,
        );
        if (written == 0) return error.BufferTooSmall;
        return self.scratch[0..written];
    }
};
