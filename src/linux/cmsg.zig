const std = @import("std");

const cmsghdr = std.os.linux.cmsghdr;

pub const cmsghdr_size = @sizeOf(cmsghdr);

pub fn alignForward(length: usize) usize {
    return std.mem.alignForward(usize, length, @alignOf(usize));
}

pub fn len(length: usize) usize {
    return alignForward(cmsghdr_size) + length;
}

pub fn space(length: usize) usize {
    return alignForward(length) + alignForward(cmsghdr_size);
}

pub fn data(cmsg: *const cmsghdr) [*]u8 {
    const ptr: usize = @intFromPtr(cmsg);
    return @ptrFromInt(ptr + cmsghdr_size);
}

pub fn nextHeader(mhdr: *const std.os.linux.msghdr, cmsg: *const cmsghdr) ?*cmsghdr {
    if (cmsg.len < cmsghdr_size) return null;

    const next_cmsg_offset = std.mem.alignForward(usize, cmsg.len, @alignOf(usize)) + cmsghdr_size;

    var mhdr_end: usize = @intFromPtr(mhdr);
    mhdr_end += mhdr.controllen;
    mhdr_end -= @intFromPtr(cmsg);

    if (next_cmsg_offset >= mhdr_end) return null;

    var next_cmsg: usize = @intFromPtr(cmsg);
    next_cmsg += std.mem.alignForward(usize, cmsg.len, @alignOf(usize));

    return @ptrFromInt(next_cmsg);
}
