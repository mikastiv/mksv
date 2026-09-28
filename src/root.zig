const std = @import("std");
const assert = std.debug.assert;

const bounded_array = @import("bounded_array.zig");
pub const BoundedArray = bounded_array.BoundedArray;
pub const BoundedArrayAligned = bounded_array.BoundedArrayAligned;
pub const hash = @import("hash.zig");
pub const image = @import("image.zig");
pub const linux = @import("linux.zig");

pub fn window(comptime T: type, buffer: []T, size: usize, advance: usize) WindowIterator(T, false) {
    assert(size != 0);
    assert(advance != 0);
    return .{
        .index = if (buffer.len > 0) 0 else null,
        .buffer = buffer,
        .size = size,
        .advance = advance,
    };
}

pub fn constWindow(comptime T: type, buffer: []const T, size: usize, advance: usize) WindowIterator(T, true) {
    assert(size != 0);
    assert(advance != 0);
    return .{
        .index = if (buffer.len > 0) 0 else null,
        .buffer = buffer,
        .size = size,
        .advance = advance,
    };
}

pub fn WindowIterator(comptime T: type, comptime is_const: bool) type {
    const BufT = if (is_const) []const T else []T;
    return struct {
        buffer: BufT,
        index: ?usize,
        size: usize,
        advance: usize,

        const Self = @This();

        /// Returns a slice of the next window, or null if window is at end.
        pub fn next(self: *Self) ?BufT {
            const start = self.index orelse return null;
            const next_index = start + self.advance;
            const end = if (start + self.size < self.buffer.len) blk: {
                self.index = if (next_index < self.buffer.len) next_index else null;
                break :blk start + self.size;
            } else blk: {
                self.index = null;
                break :blk self.buffer.len;
            };
            return self.buffer[start..end];
        }

        /// Resets the iterator to the initial window.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }
    };
}

test {
    _ = image;
    _ = hash;
    _ = bounded_array;
}
