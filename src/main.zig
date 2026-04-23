const std = @import("std");
const Io = std.Io;
const velk = @import("velk");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const w = &stdout.interface;
    try w.print("velk {s}\n", .{velk.version});
    try w.flush();
}
