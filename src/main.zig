const std = @import("std");
const mibu = @import("mibu");
const color = mibu.color;

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut();
    try stdout.writer().print("{s}Hi{s}", .{ color.fg(.red), color.reset });
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
