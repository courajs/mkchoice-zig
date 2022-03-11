const std = @import("std");
const mibu = @import("mibu"); // https://github.com/xyaman/mibu
const args_parser = @import("args"); // https://github.com/MasterQ32/zig-args

const Alloc = std.mem.Allocator;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var alloc = arena.allocator();
    _ = alloc;

    var args = try read_args(alloc);
    std.log.err("{}", .{args});

    // try do_term_stuff();
}

// Caller owns the memory
fn get_stdin_lines_alloc(alloc: Alloc) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).init(alloc);
    var stdin = std.io.getStdIn();
    var reader = stdin.reader();
    const pretty_big = 1 << 16;
    while (try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', pretty_big)) |line| {
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

fn read_args(alloc: std.mem.Allocator) !Args {
    var args = try args_parser.parseForCurrentProcess(Options, alloc, .print);
    var choices: []const []const u8 = args.positionals;
    // Check all non-raw arguments for `-`, which indicates we
    // should splice in lines from stdin.
    var end = args.raw_start_index orelse args.positionals.len;
    for (args.positionals[0..end]) |arg, idx| {
        if (std.mem.eql(u8, arg, "-")) {
            var _choices = std.ArrayList([]const u8).init(alloc);
            try _choices.appendSlice(choices[0..idx]);
            try _choices.appendSlice(try get_stdin_lines_alloc(alloc));
            try _choices.appendSlice(choices[idx + 1 ..]);
            choices = _choices.toOwnedSlice();
            break;
        }
    }
    return Args{
        .opts = args.options,
        .choices = choices,
    };
}

fn do_term_stuff() !void {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    std.debug.assert(tty.isTty());
    try tty.writer().print("{s}Hi{s}\n", .{ mibu.color.fg(.red), mibu.color.reset });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};

    var ev = try mibu.events.next(tty);
    try tty.writer().print("Key event '{s}'\n", .{ev});
}

const Options = struct {
    const Self = @This();

    prompt: []const u8 = "Choose one:",
    vanish: bool = false,
    selection: ?[]const u8 = null,
    index: ?usize = null,
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
        .n = "index",
        .p = "prompt",
        .s = "selection",
        .v = "vanish",
    };
};
const Args = struct {
    opts: Options,
    choices: []const []const u8,
};
