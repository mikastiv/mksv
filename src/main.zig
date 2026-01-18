const std = @import("std");

const Channels = enum(u8) {
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

const Pixel = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    const zero: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
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

fn hash(pixel: Pixel) usize {
    return pixel.r *% 3 +% pixel.g *% 5 +% pixel.b *% 7 +% pixel.a *% 11;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const filename = "images/dice.qoi";
    const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    defer file.close();

    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const reader = &file_reader.interface;

    const magic = try reader.takeArray(4);
    if (!std.mem.eql(u8, magic, &.{ 'q', 'o', 'i', 'f' })) return error.InvalidMagic;

    const width = try reader.takeInt(u32, .big);
    const height = try reader.takeInt(u32, .big);
    const channels = reader.takeEnum(Channels, .little) catch |err| {
        if (err == error.InvalidEnumTag)
            std.debug.print("invalid channel value\n", .{});
        return err;
    };
    const colorspace = reader.takeEnum(Colorspace, .little) catch |err| {
        if (err == error.InvalidEnumTag)
            std.debug.print("invalid colorspace value\n", .{});
        return err;
    };

    std.debug.print("magic: {s}\nwidth: {d}\nheight: {d}\nchannels: {t}\ncolorspace: {t}\n", .{ magic, width, height, channels, colorspace });

    const out_channels: Channels = .rgb;
    const size = width * height * @intFromEnum(out_channels);
    const pixels = try allocator.alloc(u8, size);
    var pixel_pos: usize = 0;

    var cache: [64]Pixel = @splat(Pixel.zero);
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
                    pixel.r +%= ((byte0 >> 4) & 0x3) -% 2;
                    pixel.g +%= ((byte0 >> 2) & 0x3) -% 2;
                    pixel.b +%= (byte0 & 0x3) -% 2;
                },
                .luma => {
                    const byte1 = try reader.takeByte();
                    const diff_green = (byte0 & 0x3f) -% 32;
                    pixel.r +%= diff_green -% 8 +% ((byte1 >> 4) & 0xf);
                    pixel.g +%= diff_green;
                    pixel.b +%= diff_green -% 8 +% (byte1 & 0xf);
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

    // const output_filename = "test.ppm";
    // const output_file = try std.fs.cwd().createFile(output_filename, .{ .truncate = true });
    // defer output_file.close();

    // var write_buffer: [1024]u8 = undefined;
    // var file_writer = output_file.writer(&write_buffer);
    // const writer = &file_writer.interface;

    // try outputImage(pixels, width, height, writer);
}

fn outputImage(buffer: []const u8, width: usize, height: usize, writer: *std.Io.Writer) !void {
    try writer.print("P3\n{d} {d}\n255\n", .{ width, height });
    for (buffer) |byte| {
        try writer.print("{d} ", .{byte});
    }

    try writer.flush();
}
