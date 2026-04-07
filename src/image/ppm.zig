const std = @import("std");
const assert = std.debug.assert;
const Format = @import("../image.zig").Format;

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

pub fn write(
    writer: *std.Io.Writer,
    pixels: []const u8,
    width: u32,
    height: u32,
    binary: bool,
) !void {
    if (width == 0) return WriteError.InvalidWidth;
    if (height == 0) return WriteError.InvalidHeight;

    const magic = if (binary) "P6" else "P3";
    const max_value = 255;

    try writer.print("{s}\n{d} {d}\n{d}\n", .{ magic, width, height, max_value });

    if (binary) {
        try writer.writeAll(pixels);
    } else {
        var index: usize = 0;
        const pixel_size = Format.rgb.size();
        while (index < pixels.len) : (index += pixel_size) {
            const r = pixels[index + 0];
            const g = pixels[index + 1];
            const b = pixels[index + 2];
            try writer.print("{d} {d} {d}\n", .{ r, g, b });
        }
    }

    try writer.flush();
}
