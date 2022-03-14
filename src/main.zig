const std = @import("std");
const mibu = @import("mibu"); // https://github.com/xyaman/mibu
const args_parser = @import("args"); // https://github.com/MasterQ32/zig-args

const input = @import("./input.zig");

const Alloc = std.mem.Allocator;

pub fn main() anyerror!u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var alloc = arena.allocator();

    var args = try read_args(alloc);

    var choice = try do_term_stuff(args);
    if (choice) |c| {
        try std.io.getStdOut().writeAll(c);
        return 0;
    } else {
        return 1;
    }
}

const RawInputReader = struct {
    pub const Self = @This();
    pub const Buffer = std.fifo.LinearFifo(u8, .{ .Static = 512 });

    tty: std.fs.File,
    buf: Buffer,
    raw: mibu.term.RawTerm,

    pub fn init(tty: std.fs.File) !Self {
        var raw = mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
        try tty.writeAll(mibu.cursor.hide());
        return Self{
            .tty = tty,
            .raw = raw,
            .buf = Buffer.init(),
        };
    }

    pub fn deinit(self: Self) !void {
        try self.tty.writeAll(mibu.cursor.show());
        try self.raw.disableRawMode();
    }
};

// todo:
// https://docs.rs/termion/latest/src/termion/input.rs.html#185-187

fn do_term_stuff(args: Args) !?[]const u8 {
    var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true });
    var user_input = try input.RawInputReader.init(tty);
    defer user_input.deinit() catch {};

    var state = RenderInfo{
        .prompt = args.opts.prompt,
        .choices = args.choices,
        .current_choice = 0,
    };
    try render(state, tty);

    while (true) {
        var ev = try user_input.next();
        switch (try handle_event(ev, &state, tty)) {
            .Done => |choice| return choice,
            .Continue => {},
        }
    }
}

const EventResponse = union(enum) {
    Done: ?[]const u8,
    Continue,
};

fn handle_event(ev: mibu.events.Event, state: *RenderInfo, tty: std.fs.File) !EventResponse {
    return switch (ev.key) {
        .ctrlC, .escape => .{ .Done = null },
        .up => {
            state.up();
            try re_render(state.*, tty);
            return .Continue;
        },
        .down => {
            state.down();
            try re_render(state.*, tty);
            return .Continue;
        },
        .ctrlM, .ctrlJ => .{ .Done = state.get_choice() },
        .char => |c| switch (c) {
            'q' => EventResponse{ .Done = null },
            ' ' => EventResponse{ .Done = state.get_choice() },
            'j' => {
                state.down();
                try re_render(state.*, tty);
                return .Continue;
            },
            'k' => {
                state.up();
                try re_render(state.*, tty);
                return .Continue;
            },
            else => .Continue,
        },
        else => .Continue,
    };
}

fn render(state: RenderInfo, tty: std.fs.File) !void {
    var writer = tty.writer();
    try state.write_prompt(writer);
    try state.write_choices(writer);
}
fn re_render(state: RenderInfo, tty: std.fs.File) !void {
    var writer = tty.writer();
    var rendered_choice_height = state.choice_height(try mibu.term.getSizeFd(tty.handle));
    try writer.writeByte('\r');
    try writer.writeAll(mibu.cursor.goUp(rendered_choice_height));
    try writer.writeAll(mibu.clear.screen_from_cursor);
    try state.write_choices(writer);
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
