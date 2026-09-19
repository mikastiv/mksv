const std = @import("std");

const cmsghdr = std.os.linux.cmsghdr;

pub fn alignForward(length: usize) usize {
    return std.mem.alignForward(usize, length, @alignOf(usize));
}

pub fn len(length: usize) usize {
    return alignForward(@sizeOf(cmsghdr)) + length;
}

pub fn space(length: usize) usize {
    return alignForward(length) + alignForward(@sizeOf(cmsghdr));
}

pub fn data(cmsg: *const cmsghdr) [*]u8 {
    const ptr: usize = @intFromPtr(cmsg);
    return @ptrFromInt(ptr + @sizeOf(cmsghdr));
}

pub fn nextHeader(mhdr: anytype, cmsg: *const cmsghdr) ?*cmsghdr {
    if (cmsg.len < @sizeOf(cmsghdr)) return null;

    const next_cmsg_offset = std.mem.alignForward(usize, cmsg.len, @alignOf(usize)) + @sizeOf(cmsghdr);

    var mhdr_end: usize = @intFromPtr(mhdr);
    mhdr_end += mhdr.controllen;
    mhdr_end -= @intFromPtr(cmsg);

    if (next_cmsg_offset >= mhdr_end) return null;

    var next_cmsg: usize = @intFromPtr(cmsg);
    next_cmsg += std.mem.alignForward(usize, cmsg.len, @alignOf(usize));

    return @ptrFromInt(next_cmsg);
}
