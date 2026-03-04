pub const qoi = @import("image/qoi.zig");
pub const ppm = @import("image/ppm.zig");

pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    format: Format,

    metadata: ?Metadata = null,
};

pub const Format = enum {
    rgb,
    rgba,

    pub fn size(self: Format) usize {
        return switch (self) {
            .rgb => 3,
            .rgba => 4,
        };
    }
};

pub const Metadata = union(enum) {
    qoi_info: qoi.Header,
};
