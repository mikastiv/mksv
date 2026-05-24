const std = @import("std");
const assert = std.debug.assert;

pub const characters = "0123456789abcdfghijklmnpqrsvwxyz";

pub fn encodedLen(src_len: usize) usize {
    return (src_len * 8 - 1) / 5 + 1;
}

pub fn encode(dest: []u8, src: []const u8) []u8 {
    const len = encodedLen(src.len);
    assert(dest.len >= len);

    var n: i32 = @intCast(len - 1);
    while (n >= 0) : (n -= 1) {
        const b = n * 5;
        const i: usize = @intCast(@divTrunc(b, 8));
        const j = @mod(b, 8);

        const lo = src[i] >> @intCast(j);
        const hi = if (i >= src.len - 1)
            0
        else
            std.math.shl(u8, src[i + 1], 8 - j);
        const c = characters[(lo | hi) & 0x1f];

        const n_u32: u32 = @intCast(n);
        const index = (len - 1) - n_u32;
        dest[index] = c;
    }

    return dest[0..len];
}

test "encode" {
    var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});
    sha256.update("abc");
    const hash = sha256.finalResult();

    var buffer: [64]u8 = undefined;
    const result = encode(&buffer, &hash);

    try std.testing.expect(std.mem.eql(u8, result, "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"));
}
