const std = @import("std");
const image = @import("image.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const filename = "images/dice.qoi";
    const file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader = &file_reader.interface;

    const img = try image.qoi.read(allocator, reader);

    const output_qoi_filename = "test.qoi";
    const output_qoi_file = try std.Io.Dir.cwd().createFile(io, output_qoi_filename, .{ .truncate = true });
    defer output_qoi_file.close(io);

    var write_buffer: [1024]u8 = undefined;
    var file_writer = output_qoi_file.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    try image.qoi.write(writer, img.pixels, img.width, img.height, .srgb);
    try writer.flush();

    const output_ppm_filename = "test.ppm";
    const output_ppm_file = try std.Io.Dir.cwd().createFile(io, output_ppm_filename, .{ .truncate = true });
    defer output_ppm_file.close(io);

    file_writer = output_ppm_file.writer(io, &write_buffer);

    try image.ppm.write(writer, img.pixels, img.width, img.height, true);
    try writer.flush();
}
