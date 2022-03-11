const std = @import("std");
const mibu = @import("mibu");
const color = mibu.color;

pub fn main() anyerror!void {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    std.debug.assert(tty.isTty());
    try tty.writer().print("{s}Hi{s}\n", .{ color.fg(.red), color.reset });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};

    var ev = try mibu.events.next(tty);
    try tty.writer().print("Key event '{s}'\n", .{ev});
}
