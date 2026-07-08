const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // In Zig 0.16.0+, the main function accepts std.process.Init ("Juicy Main").
    // This allows accessing pre-initialized resources (allocators, env vars, I/O)
    // without relying on global state.
    const io = init.io;

    // Define a buffer and initialize a buffered writer for stdout using init.io
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // Print the hello world message
    try stdout.print("Hello, World!\n", .{});

    // Flush the buffered writer to ensure output is written to terminal
    try stdout_file_writer.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
