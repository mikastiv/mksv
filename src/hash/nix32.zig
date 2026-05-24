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
        const index = len - n_u32 - 1;
        dest[index] = c;
    }

    return dest[0..len];
}

test "encode" {
    {
        var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});
        sha256.update("abc");
        const hash = sha256.finalResult();

        var buffer: [64]u8 = undefined;
        const result = encode(&buffer, &hash);

        try std.testing.expect(std.mem.eql(u8, result, "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"));
    }

    {
        var sha512: std.crypto.hash.sha2.Sha512 = .init(.{});
        sha512.update("1234512345123456789067890");
        const hash = sha512.finalResult();

        var buffer: [256]u8 = undefined;
        const result = encode(&buffer, &hash);

        try std.testing.expect(std.mem.eql(u8, result, "0vzkj9lhlnmvwbs3q5yw42lqwvz4zl8sb3z2wx779ik3fhzn1jfbi18p9hffax5jxisx47g34x70g7lpm50y2d54k2rvpap92b8p95y"));
    }
}

const invalid_char = 0xff;

const reverse_map: [256]u8 = blk: {
    var map: [256]u8 = @splat(invalid_char);

    for (0..32) |i| {
        map[characters[i]] = i;
    }

    break :blk map;
};

fn reverseLookup(char: u8) ?u8 {
    const result = reverse_map[char];
    if (result == invalid_char) return null;
    return result;
}

pub const Error = error{ InvalidChar, NoSpaceLeft };

pub fn decode(dest: []u8, src: []const u8) Error![]u8 {
    const max_len = (src.len * 5 + 7) / 8;
    @memset(dest[0..max_len], 0);

    var len: usize = 0;
    for (0..src.len) |n| {
        const c = src[src.len - n - 1];
        const digit = reverseLookup(c) orelse return Error.InvalidChar;

        const b = n * 5;
        const i = b / 8;
        const j = b % 8;

        if (i >= dest.len) return Error.NoSpaceLeft;

        dest[i] |= digit << @intCast(j);
        len = i + 1;

        if (std.math.shr(u8, digit, 8 - j) != 0) {
            if (i + 1 >= dest.len) return Error.NoSpaceLeft;

            dest[i + 1] |= std.math.shr(u8, digit, 8 - j);
            len = i + 2;
        }
    }

    return dest[0..len];
}

test "decode" {
    {
        var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});
        sha256.update("abc");
        const hash = sha256.finalResult();

        var buffer: [64]u8 = undefined;
        const result = try decode(&buffer, "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s");

        try std.testing.expect(std.mem.eql(u8, result, &hash));
    }

    {
        var sha512: std.crypto.hash.sha2.Sha512 = .init(.{});
        sha512.update("1234512345123456789067890");
        const hash = sha512.finalResult();

        var buffer: [256]u8 = undefined;
        const result = try decode(&buffer, "0vzkj9lhlnmvwbs3q5yw42lqwvz4zl8sb3z2wx779ik3fhzn1jfbi18p9hffax5jxisx47g34x70g7lpm50y2d54k2rvpap92b8p95y");

        try std.testing.expect(std.mem.eql(u8, result, &hash));
    }
}
