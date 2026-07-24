const std = @import("std");

pub const ActiveScreenshot = struct {
    path: [:0]const u8,
    stream: std.Io.net.Stream,

    pub fn respondOk(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator) void {
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll("OK\n") catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
        writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
        self.stream.close(io);
        gpa.free(self.path);
    }

    pub fn respondErr(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator, err: anyerror) void {
        var response_buf: [128]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "ERR {s}\n", .{@errorName(err)}) catch "ERR SaveFailed\n";
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll(response) catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
        writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
        self.stream.close(io);
        gpa.free(self.path);
    }

    pub fn respondQuit(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator) void {
        var write_buf: [64]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll("ERR quit\n") catch |err| std.log.warn("Emergency screenshot response write failed: {}", .{err});
        writer.interface.flush() catch |err| std.log.warn("Emergency screenshot response flush failed: {}", .{err});
        self.stream.close(io);
        gpa.free(self.path);
    }
};
