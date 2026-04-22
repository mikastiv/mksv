const std = @import("std");
const assert = std.debug.assert;
const Rgba = @import("../image.zig").Rgba;

pub const WriteError = error{
    InvalidWidth,
    InvalidHeight,
} || std.Io.Reader.Error;

pub fn write(
    writer: *std.Io.Writer,
    pixels: []Rgba,
    width: u32,
    height: u32,
    binary: bool,
) !void {
    if (width == 0) return WriteError.InvalidWidth;
    if (height == 0) return WriteError.InvalidHeight;

    const magic = if (binary) "P6" else "P3";
    const max_value = 255;

    try writer.print("{s}\n{d} {d}\n{d}\n", .{ magic, width, height, max_value });

    for (pixels) |pixel| {
        if (binary) {
            try writer.writeAll(std.mem.asBytes(&pixel)[0..3]);
        } else {
            try writer.print("{d} {d} {d}\n", .{ pixel.r, pixel.g, pixel.b });
        }
    }

    try writer.flush();
}
