const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../image.zig").Image;

const Format = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = extern struct {
    width: u32 align(1),
    height: u32 align(1),
    format: Format align(1),
    colorspace: Colorspace align(1),

    const magic: [4]u8 = .{ 'q', 'o', 'i', 'f' };
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
    InvalidQoiFile,
    InvalidHeader,
    InvalidData,
} || std.mem.Allocator.Error || std.Io.Reader.Error;

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ReadError!Image {
    const magic = try reader.takeArray(Header.magic.len);
    if (!std.mem.eql(u8, magic, &Header.magic))
        return ReadError.InvalidQoiFile;

    const header = reader.takeStruct(Header, .big) catch return ReadError.InvalidHeader;

    const size = header.width * header.height * @intFromEnum(header.format);
    const pixels = try allocator.alloc(u8, size);
    var pixel_pos: usize = 0;

    var cache: [64]Pixel = @splat(.init);
    var pixel: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    var run: u32 = 0;

    while (pixel_pos < size) : (pixel_pos += @intFromEnum(header.format)) {
        if (run > 0) {
            run -= 1;
        } else {
            const byte0 = try reader.takeByte();
            const mode: Mode = std.enums.fromInt(Mode, byte0) orelse @enumFromInt(byte0 & Mode.mask_2);
            switch (mode) {
                .index => {
                    const index: u6 = @truncate(byte0);
                    pixel = cache[index];
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
                    assert(run >= 0 and run <= 61); // stored with -1 bias (actually 1..62)
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
        if (header.format == .rgba)
            pixels[pixel_pos + 3] = pixel.a;
    }

    if (run > 0)
        return ReadError.InvalidData;

    return .{
        .pixels = pixels,
        .width = header.width,
        .height = header.height,
        .format = switch (header.format) {
            .rgb => .rgb,
            .rgba => .rgba,
        },
        .colorspace = switch (header.colorspace) {
            .srgb => .srgb,
            .linear => .linear,
        },
    };
}

const WriteError = error{
    InvalidWidth,
    InvalidHeight,
} || std.Io.Writer.Error;

const padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub fn write(writer: *std.Io.Writer, image: *const Image) !void {
    if (image.width == 0) return WriteError.InvalidWidth;
    if (image.height == 0) return WriteError.InvalidHeight;

    const format: Format = switch (image.format) {
        .rgb => .rgb,
        .rgba => .rgba,
    };

    const colorspace: Colorspace = switch (image.colorspace) {
        .srgb => .srgb,
        .linear => .linear,
    };

    const header: Header = .{
        .width = image.width,
        .height = image.height,
        .format = format,
        .colorspace = colorspace,
    };

    try writer.writeAll(&Header.magic);
    try writer.writeStruct(header, .big);

    const end = image.pixels.len - @intFromEnum(format);
    var pixel_pos: usize = 0;

    var cache: [64]Pixel = @splat(.init);
    var pixel: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var prev_pixel: Pixel = pixel;

    var run: u32 = 0;

    while (pixel_pos < image.pixels.len) : (pixel_pos += @intFromEnum(format)) {
        pixel.r = image.pixels[pixel_pos + 0];
        pixel.g = image.pixels[pixel_pos + 1];
        pixel.b = image.pixels[pixel_pos + 2];
        if (format == .rgba)
            pixel.a = image.pixels[pixel_pos + 3];

        if (pixel == prev_pixel) {
            run += 1;
            if (run == 62 or pixel_pos == end) {
                try writer.writeByte(@intFromEnum(Mode.run) | @as(u8, @truncate(run - 1)));
                run = 0;
            }
        } else {
            if (run > 0) {
                try writer.writeByte(@intFromEnum(Mode.run) | @as(u8, @truncate(run - 1)));
                run = 0;
            }

            const index: u8 = @intCast(hash(pixel) % cache.len);
            if (cache[index] == pixel) {
                try writer.writeByte(@intFromEnum(Mode.index) | index);
            } else {
                cache[index] = pixel;

                if (pixel.a == prev_pixel.a) {
                    const diff_red: i8 = @bitCast(pixel.r -% prev_pixel.r);
                    const diff_green: i8 = @bitCast(pixel.g -% prev_pixel.g);
                    const diff_blue: i8 = @bitCast(pixel.b -% prev_pixel.b);

                    const diff_green_red = diff_red -% diff_green;
                    const diff_green_blue = diff_blue -% diff_green;

                    if (diff_red > -3 and diff_red < 2 and
                        diff_green > -3 and diff_green < 2 and
                        diff_blue > -3 and diff_blue < 2)
                    {
                        const dr: u8 = @bitCast(diff_red);
                        const dg: u8 = @bitCast(diff_green);
                        const db: u8 = @bitCast(diff_blue);

                        try writer.writeByte(@intFromEnum(Mode.diff) |
                            (dr +% 2) << 4 | (dg +% 2) << 2 | (db +% 2));
                    } else if (diff_green_red > -9 and diff_green_red < 8 and
                        diff_green > -33 and diff_green < 32 and
                        diff_green_blue > -9 and diff_green_blue < 8)
                    {
                        const dg: u8 = @bitCast(diff_green);
                        const dg_r: u8 = @bitCast(diff_green_red);
                        const dg_b: u8 = @bitCast(diff_green_blue);

                        try writer.writeByte(@intFromEnum(Mode.luma) | (dg +% 32));
                        try writer.writeByte((dg_r +% 8) << 4 | (dg_b +% 8));
                    } else {
                        try writer.writeByte(@intFromEnum(Mode.rgb));
                        try writer.writeByte(pixel.r);
                        try writer.writeByte(pixel.g);
                        try writer.writeByte(pixel.b);
                    }
                } else {
                    try writer.writeByte(@intFromEnum(Mode.rgba));
                    try writer.writeByte(pixel.r);
                    try writer.writeByte(pixel.g);
                    try writer.writeByte(pixel.b);
                    try writer.writeByte(pixel.a);
                }
            }
        }
        prev_pixel = pixel;
    }

    try writer.writeAll(&padding);
}

fn hash(pixel: Pixel) usize {
    return pixel.r *% 3 +% pixel.g *% 5 +% pixel.b *% 7 +% pixel.a *% 11;
}
