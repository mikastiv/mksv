const std = @import("std");
pub const qoi = @import("image/qoi.zig");
pub const ppm = @import("image/ppm.zig");

pub const Image = struct {
    pixels: []Rgba,
    width: u32,
    height: u32,

    metadata: ?Metadata = null,
};

pub const Rgb = packed struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Rgba = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Format = enum {
    rgb,
    rgba,
};

pub const Metadata = union(enum) {
    qoi_info: qoi.Header,
};
