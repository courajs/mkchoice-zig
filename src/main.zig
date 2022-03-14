const std = @import("std");
const mibu = @import("mibu"); // https://github.com/xyaman/mibu
const args_parser = @import("args"); // https://github.com/MasterQ32/zig-args

const Alloc = std.mem.Allocator;

pub fn main() anyerror!u8 {
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

    var choice = try do_term_stuff();
    if (choice) |c| {
        try std.io.getStdOut().writeAll(c);
        return 0;
    } else {
        return 1;
    }
}

// todo:
// https://docs.rs/termion/latest/src/termion/input.rs.html#185-187

fn do_term_stuff() !?[]const u8 {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
    defer raw.disableRawMode() catch {};
    var reader = tty.reader();
    var writer = tty.writer();
    try writer.writeAll(mibu.cursor.hide());
    defer writer.writeAll(mibu.cursor.show()) catch {};

    var buf = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();

    var state = RenderInfo{
        .prompt = "Choose one:",
        .choices = &[_][]const u8{
            "first",
            "second",
            "third",
        },
        .current_choice = 0,
    };
    try render(state, writer);

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
                // std.log.err("Not supported byte sequence: {any}\r", .{buf.readableSlice(0)});
                buf.discard(buf.count);
            },
            .incomplete => {
                buf.realign();
                count = try reader.read(buf.writableSlice(0));
                buf.update(count);
            },
            .event => |ev| {
                buf.discard(ev.bytes_read);
                switch (try handle_event(ev.event, &state, writer)) {
                    .Done => |v| return v,
                    .Continue => {},
                }
            },
        }
    }
}

const EventResponse = union(enum) {
    Done: ?[]const u8,
    Continue,
};

fn handle_event(ev: mibu.events.Event, state: *RenderInfo, writer: anytype) !EventResponse {
    return switch (ev.key) {
        .ctrlC, .escape => .{ .Done = null },
        .up => {
            state.up();
            try re_render(state.*, writer);
            return .Continue;
        },
        .down => {
            state.down();
            try re_render(state.*, writer);
            return .Continue;
        },
        .ctrlM, .ctrlJ => .{ .Done = state.get_choice() },
        .char => |c| switch (c) {
            'q' => EventResponse{ .Done = null },
            ' ' => EventResponse{ .Done = state.get_choice() },
            'j' => {
                state.down();
                try re_render(state.*, writer);
                return .Continue;
            },
            'k' => {
                state.up();
                try re_render(state.*, writer);
                return .Continue;
            },
            else => .Continue,
        },
        else => .Continue,
    };
}

fn render(state: RenderInfo, writer: anytype) !void {
    try state.write_prompt(writer);
    try state.write_choices(writer);
}
fn re_render(state: RenderInfo, writer: anytype) !void {
    var rendered_choice_height = state.choice_height(try mibu.term.getSize());
    try writer.writeByte('\r');
    try writer.writeAll(mibu.cursor.goUp(rendered_choice_height));
    try writer.writeAll(mibu.clear.screen_from_cursor);
    try state.write_choices(writer);
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

const RenderInfo = struct {
    const Self = @This();

    prompt: []const u8,
    choices: []const []const u8,
    current_choice: usize,

    pub fn get_choice(self: Self) []const u8 {
        return self.choices[self.current_choice];
    }

    pub fn up(self: *Self) void {
        if (self.current_choice > 0) {
            self.current_choice -= 1;
        }
    }
    pub fn down(self: *Self) void {
        if (self.current_choice < (self.choices.len - 1)) {
            self.current_choice += 1;
        }
    }

    pub fn write_prompt(self: Self, writer: anytype) !void {
        try writer.print("{s}\r\n", .{self.prompt});
    }
    pub fn write_choices(self: Self, writer: anytype) !void {
        for (self.choices) |choice, i| {
            if (i == self.current_choice) {
                try writer.print("{s}>  {s}{s}\r\n", .{ mibu.color.fg(.green), choice, mibu.color.reset });
            } else {
                try writer.print("  {s}\r\n", .{choice});
            }
        }
    }
    pub fn full_height(self: Self, term_size: mibu.term.TermSize) usize {
        return str_height(self.prompt) + self.choice_height(term_size);
    }
    pub fn choice_height(self: Self, term_size: mibu.term.TermSize) usize {
        var height: usize = 0;
        for (self.choices) |choice, i| {
            if (i == self.current_choice) {
                height += str_height_prefixed(3, choice, term_size.width);
            } else {
                height += str_height_prefixed(2, choice, term_size.width);
            }
        }
        return height;
    }
};

fn str_height_prefixed(prefix_length: usize, s: []const u8, terminal_width: u16) usize {
    var height: usize = 0;
    var lines = std.mem.split(u8, s, "\r\n");
    if (lines.next()) |line| {
        height += 1;
        height += (prefix_length + str_width(line)) / terminal_width;
    }
    while (lines.next()) |line| {
        height += 1;
        height += str_width(line) / terminal_width;
    }
    return height;
}
fn str_height(s: []const u8, terminal_width: u16) usize {
    return str_height_prefixed(0, s, terminal_width);
}
fn str_width(s: []const u8) usize {
    // Todo: unicode & wide character support
    return s.len;
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
