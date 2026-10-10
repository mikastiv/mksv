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

    pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    pub const red: Rgb = .{ .r = 255, .g = 0, .b = 0 };
    pub const green: Rgb = .{ .r = 0, .g = 255, .b = 0 };
    pub const blue: Rgb = .{ .r = 0, .g = 0, .b = 255 };
    pub const yellow: Rgb = .{ .r = 255, .g = 255, .b = 0 };
    pub const cyan: Rgb = .{ .r = 0, .g = 255, .b = 255 };
    pub const magenta: Rgb = .{ .r = 255, .g = 0, .b = 255 };
};

pub const Rgba = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const red: Rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green: Rgba = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue: Rgba = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pub const yellow: Rgba = .{ .r = 255, .g = 255, .b = 0, .a = 255 };
    pub const cyan: Rgba = .{ .r = 0, .g = 255, .b = 255, .a = 255 };
    pub const magenta: Rgba = .{ .r = 255, .g = 0, .b = 255, .a = 255 };
};

pub const Format = enum {
    rgb,
    rgba,
};

pub const Metadata = union(enum) {
    qoi_info: qoi.Header,
};
