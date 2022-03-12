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

    // var args = try read_args(alloc);
    // const args = Args{
    //     .opts = Options{},
    //     .choices = &[_][]const u8{ "a", "b", "c" },
    // };
    // var selected = try present_choice(args);
    // std.log.err("{s}", .{selected});

    try do_term_stuff();
    // try research_reads();
}

// todo:
// https://docs.rs/termion/latest/src/termion/input.rs.html#185-187

fn do_term_stuff() !void {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};

    var buf = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
    var reader = tty.reader();
    std.log.err("Waiting for first input\r", .{});
    var count = try reader.read(buf.writableSlice(0));
    buf.update(count);

    while (true) {
        switch (try mibu.events.next(buf.readableSlice(0))) {
            .none => {
                buf.realign();
                count = try reader.read(buf.writableSlice(0));
                buf.update(count);
            },
            .not_supported => {
                std.log.err("Not supported byte sequence: {any}\r", .{buf.readableSlice(0)});
                buf.discard(buf.count);
            },
            .incomplete => {
                buf.realign();
                count = try reader.read(buf.writableSlice(0));
                buf.update(count);
            },
            .event => |ev| {
                buf.discard(ev.bytes_read);
                std.log.err("Event ({} bytes): {}\r", .{ ev.bytes_read, ev.event });
            },
        }
    }
}

fn research_reads() !void {
    var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};

    var buf: [20]u8 = undefined;

    while (true) {
        std.log.err("\r\nBlocking read...\r\n", .{});
        var bytes = try tty.read(&buf);
        std.log.err("\r\nGot {} bytes: {any}\r\n", .{ bytes, buf[0..bytes] });
        std.log.err("\r\nsleeping...\r\n", .{});
        std.time.sleep(std.time.ns_per_s * 2);
        std.log.err("\r\npost-sleep read...\r\n", .{});
        bytes = try tty.read(&buf);
        std.log.err("\r\nGot {} bytes: {any}\r\n", .{ bytes, buf[0..bytes] });
    }
}

fn present_choice(args: Args) !?[]const u8 {
    _ = args;

    var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};

    while (mibu.events.next(tty)) |ev| {
        switch (ev) {
            .key => |key| {
                switch (key) {
                    .ctrlC, .escape => {
                        return null;
                    },
                    .ctrlM => { // Enter/return
                        return "chose";
                    },
                    else => {
                        std.log.err("key event: {}\r", .{ev});
                    },
                }
            },
            else => std.log.err("unsupported event\r", .{}),
        }
    } else |_| {}

    return null;
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
