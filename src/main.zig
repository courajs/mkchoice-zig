const std = @import("std");
const args_parser = @import("args"); // https://github.com/MasterQ32/zig-args

const app = @import("./app.zig");

pub fn main() anyerror!u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var alloc = arena.allocator();

    var params = try app.load_parameters(alloc);
    return app.App.run(params);
}

// todo:
// https://docs.rs/termion/latest/src/termion/input.rs.html#185-187
