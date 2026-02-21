const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../image.zig").Image;

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const init: Pixel = .{ .r = 0, .g = 0, .b = 0 };
};

pub const WriteError = error{
    InvalidWidth,
    InvalidHeight,
} || std.Io.Reader.Error;

pub fn write(writer: *std.Io.Writer, image: *const Image, binary: bool) !void {
    if (image.width == 0) return WriteError.InvalidWidth;
    if (image.height == 0) return WriteError.InvalidHeight;

    const magic = if (binary) "P6" else "P3";
    const max_value = 255;

    try writer.print("{s}\n{d} {d}\n{d}\n", .{ magic, image.width, image.height, max_value });

    if (binary) {
        try writer.writeAll(image.pixels);
    } else {
        var index: usize = 0;
        const pixel_size = image.format.size();
        while (index < image.pixels.len) : (index += pixel_size) {
            const r = image.pixels[index + 0];
            const g = image.pixels[index + 1];
            const b = image.pixels[index + 2];
            try writer.print("{d} {d} {d}\n", .{ r, g, b });
        }
    }

    try writer.flush();
}
