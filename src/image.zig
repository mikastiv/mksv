pub const qoi = @import("image/qoi.zig");

pub const Colorspace = enum {
    srgb,
    linear,
};

pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u8,
    colorspace: Colorspace,
};
