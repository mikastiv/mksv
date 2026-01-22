const std = @import("std");
const image = @import("image.zig");

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

    const img = try image.qoi.read(allocator, reader);

    const output_filename = "test.qoi";
    const output_file = try std.fs.cwd().createFile(output_filename, .{ .truncate = true });
    defer output_file.close();

    var write_buffer: [1024]u8 = undefined;
    var file_writer = output_file.writer(&write_buffer);
    const writer = &file_writer.interface;

    try image.qoi.write(writer, &img);
    try writer.flush();

    // try outputImage(img.pixels, img.width, img.height, writer);
}

fn outputImage(buffer: []const u8, width: usize, height: usize, writer: *std.Io.Writer) !void {
    try writer.print("P3\n{d} {d}\n255\n", .{ width, height });
    for (buffer) |byte| {
        try writer.print("{d} ", .{byte});
    }

    try writer.flush();
}
