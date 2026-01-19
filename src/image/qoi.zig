const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../image.zig").Image;

pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = struct {
    magic: [4]u8,
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,
};

const Mode = enum(u8) {
    index = 0b0000_0000,
    diff = 0b0100_0000,
    luma = 0b1000_0000,
    run = 0b1100_0000,
    rgb = 0b1111_1110,
    rgba = 0b1111_1111,

    const mask_2 = 0b1100_0000;
};

const Pixel = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const init: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

pub const ReadError = error{
    InvalidChannelValue,
    InvalidQoiFile,
    InvalidColorspaceValue,
} || std.mem.Allocator.Error || std.Io.Reader.Error;

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    wanted_channels: ?Channels,
) ReadError!Image {
    const magic = try reader.takeArray(4);
    if (!std.mem.eql(u8, magic, &.{ 'q', 'o', 'i', 'f' }))
        return ReadError.InvalidQoiFile;

    const width = try reader.takeInt(u32, .big);
    const height = try reader.takeInt(u32, .big);

    const channels = reader.takeEnum(Channels, .little) catch |err| {
        if (err == error.InvalidEnumTag)
            return ReadError.InvalidChannelValue;
        return @errorCast(err);
    };

    const colorspace = reader.takeEnum(Colorspace, .little) catch |err| {
        if (err == error.InvalidEnumTag)
            return ReadError.InvalidColorspaceValue;
        return @errorCast(err);
    };

    const out_channels = wanted_channels orelse .rgba;
    const size = width * height * @intFromEnum(out_channels);
    const pixels = try allocator.alloc(u8, size);
    var pixel_pos: usize = 0;

    var cache: [64]Pixel = @splat(.init);
    var pixel: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    var run: usize = 0;

    while (pixel_pos < size) : (pixel_pos += @intFromEnum(out_channels)) {
        if (run > 0) {
            run -= 1;
        } else {
            const byte0 = try reader.takeByte();
            const mode: Mode = std.enums.fromInt(Mode, byte0) orelse @enumFromInt(byte0 & Mode.mask_2);
            switch (mode) {
                .index => {
                    pixel = cache[byte0];
                },
                .diff => {
                    const diff_red = (byte0 >> 4) & 0x3;
                    const diff_green = (byte0 >> 2) & 0x3;
                    const diff_blue = byte0 & 0x3;

                    pixel.r +%= diff_red -% 2;
                    pixel.g +%= diff_green -% 2;
                    pixel.b +%= diff_blue -% 2;
                },
                .luma => {
                    const byte1 = try reader.takeByte();

                    const diff_green = (byte0 & 0x3f) -% 32;
                    const diff_red = (byte1 >> 4) & 0xf;
                    const diff_blue = byte1 & 0xf;

                    pixel.r +%= diff_green -% 8 +% diff_red;
                    pixel.g +%= diff_green;
                    pixel.b +%= diff_green -% 8 +% diff_blue;
                },
                .run => {
                    run = byte0 & 0x3f;
                },
                .rgb, .rgba => {
                    pixel.r = try reader.takeByte();
                    pixel.g = try reader.takeByte();
                    pixel.b = try reader.takeByte();
                    if (mode == .rgba)
                        pixel.a = try reader.takeByte();
                },
            }

            cache[hash(pixel) % cache.len] = pixel;
        }

        pixels[pixel_pos + 0] = pixel.r;
        pixels[pixel_pos + 1] = pixel.g;
        pixels[pixel_pos + 2] = pixel.b;
        if (out_channels == .rgba)
            pixels[pixel_pos + 3] = pixel.a;
    }

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = @intFromEnum(channels),
        .colorspace = switch (colorspace) {
            .srgb => .srgb,
            .linear => .linear,
        },
    };
}

fn hash(pixel: Pixel) usize {
    return pixel.r *% 3 +% pixel.g *% 5 +% pixel.b *% 7 +% pixel.a *% 11;
}
